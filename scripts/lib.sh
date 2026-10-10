# Image Gen MCP: the shared code of setup.sh, start.sh and update.sh. They cd to the project folder, load this file
# and run its steps:
#   step 1  check_docker   Docker is installed and running (skipped on a Mac)
#   2-3b    run_setup      where the server runs and which model it uses, saved in config.yaml
#   step 4  start_server   build the image, start the server, download the model, wait until it is loaded
#           run_update     install the latest version with git
# Keep it bash 3.2 compatible (macOS): no sed -i, ${x,,}, mapfile or associative arrays.
# Keep the texts and the model choices the same as in scripts/lib.ps1 (tests/test_start_scripts.py checks them).

REPO_URL=https://github.com/hypersniper05/MCP-Image-Generator-Uncensored
OS=$(uname -s 2>/dev/null || echo unknown)
# Set by the update when the server code changed: the next start builds the image again.
BUILD_MARK=.build-needed

# launcher NAME: how the person runs that script: setup.command (Mac Finder) or ./setup.sh.
launcher() { if [ "${IMAGEGEN_LAUNCH:-}" = command ]; then echo "$1.command"; else echo "./$1.sh"; fi; }
LAUNCHER=${LAUNCHER:-$(launcher start)}
# interactive: true when a person runs this in a terminal, so questions can be asked.
interactive() { [ -t 0 ] && [ -t 1 ]; }

# The model choices, the same rows as in scripts/lib.ps1:
# name|variant|quant|text encoder quant|download GB|seconds per 1024x1024 image on a 12 GB GPU|needs
presets() {
  cat <<'EOF'
Best quality|uncensored|Q4_K_M|Q8_0|15.5|90|GPU 12 GB+, 20 GB memory
Standard|uncensored|Q4_K_M|Q4_K_M|11.8|90|GPU 12 GB+, 16 GB memory
Turbo|turbo|Q4_K_M|Q4_K_M|11.4|12|GPU 8 GB+ or CPU, 16 GB memory
EOF
}
PRESET_COUNT=3
TURBO=3   # the choice for small GPUs, the CPU and Macs

preset() { presets | sed -n "${1}p"; }
pf() { printf '%s\n' "$1" | cut -d'|' -f"$2"; }
describe() { echo "$(pf "$1" 1) ($(pf "$1" 2) $(pf "$1" 3), text encoder $(pf "$1" 4))"; }

# --- input ------------------------------------------------------------------------------------------------------------
# ask PROMPT DEFAULT: sets ANSWER (DEFAULT when only Enter is pressed). End of input quits.
ask() {
  ANSWER=
  printf '%s [%s]: ' "$1" "$2"
  if ! read -r ANSWER; then echo; exit 1; fi
  ANSWER=${ANSWER:-$2}
}
# yes_no QUESTION y|n: true for yes. The second argument is the answer when only Enter is pressed.
yes_no() {
  local a d='[y/N]'
  if [ "$2" = y ]; then d='[Y/n]'; fi
  printf '%s %s ' "$1" "$d"
  if ! read -r a; then echo; exit 1; fi
  case "${a:-$2}" in [yY]*) return 0 ;; *) return 1 ;; esac
}
# read_choice MAX DEFAULT: sets CHOICE to a number from 1 to MAX.
read_choice() {
  while :; do
    ask "Type a number and press Enter" "$2"
    case "$ANSWER" in
      [1-9]) if [ "$ANSWER" -le "$1" ]; then CHOICE=$ANSWER; return 0; fi ;;
    esac
    echo "Please type a number from 1 to $1."
  done
}

# --- config.yaml ------------------------------------------------------------------------------------------------------
# set_yaml FILE KEY VALUE [SECTION]: set "KEY: VALUE" and keep the rest of the line (its comment). With a
# SECTION, only that top-level section is searched (vae: is both in model: and in gpu:). The file is rewritten in
# place (same file, same owner).
set_yaml() {
  if awk -v k="$2" -v v="$3" -v s="${4:-}" '
    function top() { if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/) { cur = $0; sub(/[ \t]*:.*/, "", cur) } }
    BEGIN { pat = "^" ((s == "") ? "" : "[ \t]+") k "[ \t]*:" }
    NR == FNR {
      top()
      if ((s == "" || cur == s) && $0 ~ pat) has = 1
      if (s != "" && $0 ~ ("^" s ":[ \t]*[{[]")) flow = 1
      next
    }
    FNR == 1 { cur = ""; if (flow && !has) bad = 1 }
    { top() }
    has && !done && (s == "" || cur == s) && $0 ~ pat {
      match($0, pat "[ \t]*"); head = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1)
      if (rest ~ /^\{/) sub(/^\{[^}]*\}/, "", rest)
      else if (rest ~ /^\[/) sub(/^\[[^]]*\]/, "", rest)
      else sub(/^[^ \t\r#]*/, "", rest)
      print head v rest; done = 1; next
    }
    { print }
    !has && !bad && s != "" && !done && $0 ~ ("^" s ":[ \t]*(#.*)?$") { print "  " k ": " v; done = 1 }
    END { if (bad) exit 3; if (!done) { if (s != "") print s ":"; print (s != "" ? "  " : "") k ": " v } }
  ' "$1" "$1" > "$1.tmp" && cat "$1.tmp" > "$1"; then
    rm -f "$1.tmp"
    return 0
  fi
  rm -f "$1.tmp"
  echo "config.yaml: change ${4:+$4.}$2 by hand (this layout is not supported)" >&2
  return 1
}
# set_model FILE PRESET_LINE: write the three model keys.
set_model() {
  set_yaml "$1" variant "$(pf "$2" 2)" model && set_yaml "$1" quant "$(pf "$2" 3)" model &&
    set_yaml "$1" text_encoder_quant "$(pf "$2" 4)" model
}
# yaml_in SECTION KEY: KEY's value inside the top-level SECTION of config.yaml, without its comment and quotes.
yaml_in() {
  awk -v s="$1" -v k="$2" '
    /^[A-Za-z_]/ { cur = $0; sub(/[ \t]*:.*/, "", cur) }
    cur == s && $0 ~ "^[ \t]+" k "[ \t]*:" {
      v = $0; sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t]*#.*/, "", v); gsub(/["\047\r]/, "", v); print v; exit }
  ' config.yaml 2>/dev/null || true
}
# read_model: sets CUR_PRESET, the number of the model choice in config.yaml (0 = none of them, or no config.yaml),
# and CUR_MODEL_TEXT ("uncensored Q4_K_M, text encoder Q8_0").
read_model() {
  local v q t
  CUR_PRESET=0; CUR_MODEL_TEXT=
  if [ ! -f config.yaml ]; then return 0; fi
  v=$(yaml_in model variant | tr '[:upper:]' '[:lower:]'); v=${v:-uncensored}
  q=$(yaml_in model quant | tr '[:lower:]' '[:upper:]' | sed 's/^AD-//'); q=${q:-Q4_K_M}
  case "$q" in Q4|Q4_K) q=Q4_K_M ;; Q5|Q5_K) q=Q5_K_M ;; Q6) q=Q6_K ;; Q8) q=Q8_0 ;; esac
  t=$(yaml_in model text_encoder_quant | tr '[:lower:]' '[:upper:]'); t=${t:-Q4_K_M}
  CUR_MODEL_TEXT="$v $q, text encoder $t"
  CUR_PRESET=$(presets | awk -F'|' -v v="$v" -v q="$q" -v t="$t" '$2 == v && $3 == q && $4 == t { print NR; f = 1; exit }
    END { if (!f) print 0 }')
}
current_model() {
  read_model
  if [ "$CUR_PRESET" -gt 0 ]; then echo "$(pf "$(preset "$CUR_PRESET")" 1) ($CUR_MODEL_TEXT)"
  else echo "custom ($CUR_MODEL_TEXT)"
  fi
}
# read_current: the saved device and GPU places (CUR_DEVICE, CUR_IMG "0" or "0 2", CUR_TE and CUR_DEC "2" or "cpu").
read_current() {
  CUR_DEVICE=; CUR_IMG=; CUR_TE=; CUR_DEC=
  if [ ! -f config.yaml ]; then return 0; fi
  CUR_DEVICE=$(sed -nE 's/^device[[:space:]]*:[[:space:]]*"?([A-Za-z]+).*/\1/p' config.yaml | head -n1 |
    tr '[:upper:]' '[:lower:]')
  CUR_IMG=$(yaml_in gpu diffusion | tr -d '[]' | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'); CUR_IMG=${CUR_IMG:-0}
  CUR_TE=$(yaml_in gpu text_encoder); CUR_TE=${CUR_TE:-${CUR_IMG%% *}}
  CUR_DEC=$(yaml_in gpu vae); CUR_DEC=${CUR_DEC:-${CUR_IMG%% *}}
}

# --- this computer ----------------------------------------------------------------------------------------------------
# detect: sets IS_MAC, IS_WINDOWS, DOCKER_GB (0 = unknown), GPU_ROWS ("index|name|GB" per NVIDIA GPU), GPU_COUNT,
# and for the first GPU GPU_INDEX, GPU_NAME (empty = no NVIDIA GPU) and VRAM_GB.
detect() {
  local mem rows
  IS_MAC=0; IS_WINDOWS=0
  case "$OS" in
    Darwin) IS_MAC=1 ;;
    MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
    *) if grep -qi microsoft /proc/version 2>/dev/null; then IS_WINDOWS=1; fi ;;
  esac
  mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null | tr -d '\r') || mem=
  case "$mem" in ''|*[!0-9]*) mem=0 ;; esac
  DOCKER_GB=$(( (mem + 536870912) / 1073741824 ))
  GPU_ROWS=; GPU_NAME=; GPU_INDEX=0; GPU_COUNT=0; VRAM_GB=0
  if [ "$IS_MAC" = 1 ] || ! command -v nvidia-smi >/dev/null 2>&1; then return 0; fi
  rows=$(nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader,nounits 2>/dev/null | tr -d '\r') ||
    rows=
  GPU_ROWS=$(printf '%s\n' "$rows" | awk -F', *' '$1 ~ /^[0-9]+$/ && $NF ~ /^[0-9]+$/ {
    name = $2; for (i = 3; i < NF; i++) name = name ", " $i
    printf "%s|%s|%d\n", $1, name, int(($NF + 512) / 1024) }')
  GPU_COUNT=$(printf '%s\n' "$GPU_ROWS" | awk -F'|' 'NF == 3 { n++ } END { print n + 0 }')
  if [ "$GPU_COUNT" -eq 0 ]; then return 0; fi
  use_gpus "$(first_gpu)"
}
first_gpu() { printf '%s\n' "$GPU_ROWS" | head -n1 | cut -d'|' -f1; }
# gpu_gb INDEX: the memory of that GPU in GB (empty when there is no such GPU).
gpu_gb() { printf '%s\n' "$GPU_ROWS" | awk -F'|' -v i="$1" '$1 == i { print $3; exit }'; }
# use_gpus "INDEX [INDEX...]": sets GPU_INDEX (the first one), GPU_NAME and VRAM_GB (their total).
use_gpus() {
  local i gb
  GPU_INDEX=${1%% *}; VRAM_GB=0
  GPU_NAME=$(printf '%s\n' "$GPU_ROWS" | awk -F'|' -v i="$GPU_INDEX" '$1 == i { print $2; exit }')
  for i in $1; do gb=$(gpu_gb "$i"); VRAM_GB=$((VRAM_GB + ${gb:-0})); done
}
cpu_name() {
  local n
  if [ "$OS" = Darwin ]; then n=$(sysctl -n machdep.cpu.brand_string 2>/dev/null) || n=
  else n=$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n1) || n=
  fi
  echo "${n:-your CPU}"
}
gpu_label() { printf '%s\n' "$GPU_ROWS" | awk -F'|' -v i="$1" '$1 == i { print "GPU " $1 " (" $2 ", " $3 " GB)"; exit }'; }
place_label() {
  local i out=
  if [ "$1" = cpu ]; then echo "CPU ($(cpu_name))"; return 0; fi
  for i in $1; do out="${out:+$out + }$(gpu_label "$i")"; done
  echo "$out"
}
# place_short PLACE: "CPU", "GPU 2" or "GPU 0 + GPU 2".
place_short() { if [ "$1" = cpu ]; then echo CPU; else echo "GPU $(printf '%s' "$1" | sed 's/ / + GPU /g')"; fi; }
# device_text: where the server runs, from config.yaml: "CPU", "GPU 2 (NVIDIA GeForce RTX 3080 Ti, 12 GB)" or a split.
# Needs detect for the GPU names.
device_text() {
  local one
  read_current
  if [ "$CUR_DEVICE" = cpu ]; then echo CPU; return 0; fi
  if [ "$CUR_IMG" = "$CUR_TE" ] && [ "$CUR_TE" = "$CUR_DEC" ]; then
    one=$(gpu_label "$CUR_IMG"); echo "${one:-GPU $CUR_IMG}"; return 0
  fi
  echo "image model on $(place_short "$CUR_IMG"), text encoder on $(place_short "$CUR_TE"), image decoder on $(
    place_short "$CUR_DEC")"
}
show_settings() {
  echo "    Model:  $(current_model)"
  echo "    Device: $(device_text)"
}

# --- step 1: Docker ---------------------------------------------------------------------------------------------------
# When Docker is missing or not running, say what to do and stop (nothing is started for the person).
check_docker() {
  local desktop=0 docker_err
  if [ "$OS" = Darwin ]; then return 0; fi
  case "$OS" in MINGW*|MSYS*|CYGWIN*) desktop=1 ;; esac
  echo "==> Checking Docker..."
  if ! command -v docker >/dev/null 2>&1; then
    if [ "$desktop" = 1 ]; then
      echo "Docker is not installed. The image server needs Docker Desktop." >&2
      echo "  1. Download and install it: https://www.docker.com/products/docker-desktop/" >&2
      echo "  2. Open Docker Desktop and wait until it says Engine running." >&2
    else
      echo "Docker is not installed. The image server needs Docker Engine with Compose." >&2
      echo "  1. Install it: https://docs.docker.com/engine/install/" >&2
      echo "  2. Start it (for example: sudo systemctl start docker)." >&2
    fi
    echo "  3. Run $LAUNCHER again." >&2
    exit 1
  fi
  if ! docker_err=$(docker info 2>&1 >/dev/null); then
    case "$docker_err" in
      *"permission denied"*)
        echo "Docker is running, but your user may not use it. Run: sudo usermod -aG docker \$USER," >&2
        echo "then log out, log back in and run $LAUNCHER again." >&2 ;;
      *)
        if [ "$desktop" = 1 ]; then
          echo "Docker is installed but not running. Start Docker Desktop, wait until it says Engine running," >&2
          echo "then run $LAUNCHER again." >&2
        else
          echo "Docker is installed but not running. Start it (for example: sudo systemctl start docker)," >&2
          echo "then run $LAUNCHER again." >&2
        fi ;;
    esac
    exit 1
  fi
  echo "    Docker is running."
}

# --- step 2: which GPU ------------------------------------------------------------------------------------------------
# choose_gpus DEFAULT: show the GPUs; with more than one, ask which one to use. Sets SPLIT and PLACE_IMG. The last
# choice, split, is set up after the model is chosen (split_gpus), because how to split depends on the model's size.
choose_gpus() {
  local idx name gb
  SPLIT=0
  if [ "$GPU_COUNT" -eq 1 ]; then echo "    GPU: $GPU_NAME, $VRAM_GB GB"; PLACE_IMG=$GPU_INDEX; return 0; fi
  echo "    GPUs found:"
  printf '%s\n' "$GPU_ROWS" | while IFS='|' read -r idx name gb; do echo "      $idx) $name, $gb GB"; done
  echo "      $GPU_COUNT) Split the model across several GPUs"
  echo
  echo "Which GPU should the image server use?"
  while :; do
    ask "Type a number and press Enter" "$1"
    case "$ANSWER" in
      *[!0-9]*|'') ;;
      *)
        if [ "$ANSWER" -eq "$GPU_COUNT" ]; then
          SPLIT=1
          use_gpus "$(printf '%s\n' "$GPU_ROWS" | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//')"
          echo "    The split is set up after you choose the model."
          return 0
        fi
        if [ -n "$(gpu_gb "$ANSWER")" ]; then use_gpus "$ANSWER"; PLACE_IMG=$ANSWER; return 0; fi ;;
    esac
    echo "Please type a number from 0 to $GPU_COUNT."
  done
}
# cpu_ok REASON: say why only the CPU is possible and ask whether to go on. No ends the setup.
cpu_ok() {
  echo
  echo "$1"
  if yes_no "Continue on the CPU (several minutes per image)?" y; then return 0; fi
  if [ "$IS_MAC" = 1 ]; then
    echo "Nothing was changed. Run $LAUNCHER again when you want to set it up."
  else
    echo "Nothing was changed. If you have an NVIDIA GPU, install its driver, then run $LAUNCHER again."
  fi
  exit 0
}

# --- step 3: the model ------------------------------------------------------------------------------------------------
# recommend: sets DEVICE_REC and PRESET_REC.
recommend() {
  if [ "$IS_MAC" = 1 ] || [ "$VRAM_GB" -lt 8 ]; then DEVICE_REC=cpu; PRESET_REC=$TURBO; return 0; fi
  DEVICE_REC=gpu
  if [ "$VRAM_GB" -lt 12 ]; then PRESET_REC=$TURBO
  elif [ "$DOCKER_GB" -ge 20 ]; then PRESET_REC=1
  else PRESET_REC=2
  fi
}
# show_presets RECOMMENDED cpu|gpu CURRENT: print the model choices (CURRENT 0 = no current model).
show_presets() {
  local i=0 name v q t gb sec need tm mark
  echo "    Choice          Download  Time per image  Needs"
  presets | while IFS='|' read -r name v q t gb sec need; do
    i=$((i + 1)); tm="~$sec s"; mark=
    if [ "$2" = cpu ]; then tm=minutes; need=$(printf '%s' "$need" | sed 's/^.*, //'); fi
    if [ "$i" = "$3" ] && [ "$i" = "$1" ]; then mark="  <- current, recommended"
    elif [ "$i" = "$3" ]; then mark="  <- current"
    elif [ "$i" = "$1" ]; then mark="  <- recommended"
    fi
    printf ' %d) %-15s %5s GB  %-14s  %s%s\n' "$i" "$name" "$gb" "$tm" "$need" "$mark"
  done
  echo
  if [ "$2" = cpu ]; then
    echo " On the CPU every image takes several minutes. 1 and 2 use the uncensored model."
  else
    echo " Times are for one 1024x1024 image on a 12 GB GPU. 1 and 2 use the uncensored model."
  fi
  echo " $TURBO uses the official Turbo model (not uncensored): much faster, weaker at small text."
}
# pick_preset MAX DEFAULT: sets CHOICE. Best quality with little memory for Docker asks first.
pick_preset() {
  while :; do
    read_choice "$1" "$2"
    if [ "$CHOICE" != 1 ] || [ "$DOCKER_GB" -eq 0 ] || [ "$DOCKER_GB" -ge 20 ]; then return 0; fi
    echo "Best quality needs 20 GB of memory for Docker, but Docker can use only $DOCKER_GB GB."
    if yes_no "Use it anyway?" n; then return 0; fi
  done
}

# --- step 3b: where each part of the model runs (only after "Split") --------------------------------------------------
# Sizes in GB of the parts of a model choice (the files the server loads).
image_gb() { case "$(pf "$1" 2)" in turbo) echo 4.2 ;; *) echo 4.6 ;; esac; }
encoder_gb() { case "$(pf "$1" 4)" in Q8_0) echo 8.7 ;; F16) echo 16.4 ;; *) echo 5.0 ;; esac; }
DECODER_GB=0.7
# part_default PLACE multi|cpu: the menu number for a saved place (the first GPU when it is not valid here).
part_default() {
  case "$1" in
    *' '*) if [ "$2" = multi ]; then echo "$GPU_COUNT"; return 0; fi ;;
    cpu) if [ "$2" = cpu ]; then echo "$GPU_COUNT"; return 0; fi ;;
    *) if [ -n "$(gpu_gb "$1")" ]; then echo "$1"; return 0; fi ;;
  esac
  first_gpu
}
# place_part NAME GB multi|cpu DEFAULT: ask where one part runs. Sets PLACE: "cpu", one GPU number, or several.
place_part() {
  local idx name gb extra
  extra=$GPU_COUNT
  echo
  echo "$1 ($2 GB): where should it run?"
  printf '%s\n' "$GPU_ROWS" | while IFS='|' read -r idx name gb; do echo "  $idx) GPU $idx: $name, $gb GB"; done
  if [ "$3" = multi ]; then echo "  $extra) Several GPUs (split it)"; else echo "  $extra) CPU: $(cpu_name)"; fi
  while :; do
    ask "Type a number and press Enter" "$4"
    case "$ANSWER" in
      *[!0-9]*|'') ;;
      *)
        if [ -n "$(gpu_gb "$ANSWER")" ]; then PLACE=$ANSWER; return 0; fi
        if [ "$ANSWER" -eq "$extra" ] && [ "$3" = cpu ]; then PLACE=cpu; return 0; fi
        if [ "$ANSWER" -eq "$extra" ] && [ "$3" = multi ]; then pick_gpus; return 0; fi ;;
    esac
    echo "Please type a number from 0 to $extra."
  done
}
# pick_gpus: two or more GPUs for the image model (the saved ones are the default). Sets PLACE.
pick_gpus() {
  local all list i bad
  all=$(printf '%s\n' "$GPU_ROWS" | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')
  list=$all
  case "${CUR_IMG:-}" in *' '*) list=$(printf '%s' "$CUR_IMG" | tr ' ' ',') ;; esac
  while :; do
    ask "Which GPUs? Type their numbers separated by commas" "$list"
    list=$(printf '%s' "$ANSWER" | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')
    bad=0
    for i in $list; do
      case "$i" in *[!0-9]*) bad=1 ;; *) if [ -z "$(gpu_gb "$i")" ]; then bad=1; fi ;; esac
    done
    if [ "$bad" = 0 ] && [ "$(printf '%s\n' $list | sort -u | wc -l | tr -d ' ')" -ge 2 ] &&
       [ "$(printf '%s\n' $list | sort -u | wc -l)" -eq "$(printf '%s\n' $list | wc -l)" ]; then
      PLACE=$list
      return 0
    fi
    list=$all
    echo "Please type two or more different GPU numbers from the list, for example $all."
  done
}
# split_gpus PRESET_LINE: place the image model, the text encoder and the image decoder one by one, then show
# all three with a warning for any GPU that may run out of memory, and confirm or start over.
# Sets PLACE_IMG, PLACE_TE and PLACE_DEC.
split_gpus() {
  local img te dec ig eg warn
  ig=$(image_gb "$1"); eg=$(encoder_gb "$1")
  echo
  echo "Split $(pf "$1" 1): choose where each part of the model runs."
  while :; do
    place_part "Image model" "$ig" multi "$(part_default "$CUR_IMG" multi)"; img=$PLACE
    place_part "Text encoder" "$eg" cpu "$(part_default "$CUR_TE" cpu)"; te=$PLACE
    place_part "Image decoder" "$DECODER_GB" cpu "$(part_default "$CUR_DEC" cpu)"; dec=$PLACE
    echo
    echo "Your split:"
    printf '    %-24s %s\n' "Image model ($ig GB):" "$(place_label "$img")"
    printf '    %-24s %s\n' "Text encoder ($eg GB):" "$(place_label "$te")"
    printf '    %-24s %s\n' "Image decoder ($DECODER_GB GB):" "$(place_label "$dec")"
    # Memory each GPU needs: the files plus working memory (image model +3 GB, split evenly; decoder +2.5 GB).
    # On a GPU under 20 GB the server keeps the text encoder's weights in RAM, so it needs about 1.5 GB there.
    warn=$(printf '%s\n' "$GPU_ROWS" | awk -F'|' -v img="$img" -v te="$te" -v dec="$dec" -v ig="$ig" -v eg="$eg" '
      { n = split(img, a, " "); need = 0
        for (j = 1; j <= n; j++) if (a[j] == $1) need += (ig + 3) / n
        if (te == $1) need += ($3 < 20) ? 1.5 : eg + 2.2
        if (dec == $1) need += 0.7 + 2.5
        if (need > 0 && need > $3 - 2)
          printf "    GPU %s (%s, %s GB) may run out of memory: its parts need about %.0f GB.\n", $1, $2, $3, need }')
    if [ -n "$warn" ]; then
      echo
      echo "$warn"
      echo "    The server then works more slowly (it moves parts to RAM) or stops with an out-of-memory error."
    fi
    echo
    echo "  1) Confirm"
    echo "  2) Start over"
    read_choice 2 1
    if [ "$CHOICE" = 1 ]; then break; fi
  done
  PLACE_IMG=$img; PLACE_TE=$te; PLACE_DEC=$dec
}

# --- saving the answers -----------------------------------------------------------------------------------------------
# write_config FILE PRESET_LINE: config.yaml (or, the first time, config.example.yaml) with the device, the GPU places,
# a memory limit for each GPU under 20 GB and the model. Other settings in config.yaml are kept. Sets GPU_NOTE, a line
# that describes the GPU settings.
write_config() {
  local i gb used caps= limits= cache=auto offload=auto
  GPU_NOTE=
  if [ -f config.yaml ]; then cp config.yaml "$1"; else cp config.example.yaml "$1"; fi || return 1
  set_yaml "$1" device "$DEVICE_REC" || return 1
  if [ "$DEVICE_REC" = gpu ]; then
    used=$(printf '%s\n' $PLACE_IMG $PLACE_TE $PLACE_DEC | grep -v '^cpu$' | sort -un | tr '\n' ' ')
    for i in $used; do
      gb=$(gpu_gb "$i")
      if [ "${gb:-0}" -lt 20 ]; then
        caps="${caps:+$caps, }$i: $((gb - 2))"; limits="${limits:+$limits, }GPU $i limited to $((gb - 2)) GB"
      fi
    done
    if [ -n "$caps" ]; then cache=q8_0; fi
    # On a GPU under 20 GB the text encoder's weights stay in RAM.
    if [ "$PLACE_TE" != cpu ] && [ "$(gpu_gb "$PLACE_TE")" -lt 20 ]; then offload="{text_encoder: cpu}"; fi
    set_yaml "$1" diffusion "[$(printf '%s' "$PLACE_IMG" | sed 's/ /, /g')]" gpu &&
      set_yaml "$1" text_encoder "$PLACE_TE" gpu && set_yaml "$1" vae "$PLACE_DEC" gpu &&
      set_yaml "$1" max_vram_gb "{$caps}" gpu && set_yaml "$1" offload "$offload" gpu &&
      set_yaml "$1" prefix_cache_type "$cache" generation || return 1
    if [ "$PLACE_IMG" = "$PLACE_TE" ] && [ "$PLACE_TE" = "$PLACE_DEC" ]; then
      gb=$(gpu_gb "$PLACE_IMG")
      if [ "$gb" -lt 20 ]; then GPU_NOTE="GPU $PLACE_IMG (limited to $((gb - 2)) GB); text encoder weights in RAM"
      else GPU_NOTE="GPU $PLACE_IMG"
      fi
    else
      GPU_NOTE="image model on $(place_short "$PLACE_IMG"), text encoder on $(place_short "$PLACE_TE"), image decoder on $(
        place_short "$PLACE_DEC")${limits:+ ($limits)}"
    fi
  fi
  set_model "$1" "$2"
}

# --- steps 2 to 3b: the setup -----------------------------------------------------------------------------------------
# Asks where the server runs and which model it uses and saves the answers in config.yaml. When config.yaml exists,
# its settings are the defaults, so Enter keeps them.
run_setup() {
  local p tmp cur gpu_default=
  if ! interactive; then
    echo "The setup asks questions, so run $(launcher setup) in a terminal." >&2
    exit 1
  fi
  detect
  read_current
  read_model
  cur=$CUR_PRESET
  echo
  if [ -f config.yaml ]; then
    echo "==> Setup. Your current settings are the defaults: press Enter to keep them."
    show_settings
  else
    echo "==> First-time setup"
  fi
  echo
  # Step 2: where the server runs.
  if [ "$DOCKER_GB" -gt 0 ]; then echo "    Memory Docker can use: $DOCKER_GB GB"; fi
  if [ "$IS_MAC" = 1 ]; then
    cpu_ok "This is a Mac. Docker on macOS cannot use the Mac's GPU, so the server runs on the CPU."
  elif [ "$GPU_COUNT" -eq 0 ]; then
    cpu_ok "No NVIDIA GPU was found, so the server can only run on the CPU."
  else
    gpu_default=$(first_gpu)
    if [ "$CUR_DEVICE" = gpu ]; then
      if [ "$CUR_IMG" != "$CUR_TE" ] || [ "$CUR_TE" != "$CUR_DEC" ]; then gpu_default=$GPU_COUNT
      elif [ -n "$(gpu_gb "$CUR_IMG")" ]; then gpu_default=$CUR_IMG
      fi
    fi
    choose_gpus "$gpu_default"
    if [ "$VRAM_GB" -lt 8 ]; then
      cpu_ok "That GPU has only $VRAM_GB GB of memory (8 GB or more is needed), so the server can only run on the CPU."
    elif [ "$VRAM_GB" -lt 12 ]; then
      echo
      echo "Note: GPUs with less than 12 GB have not been tested. Choice $TURBO is the most likely to fit."
    fi
  fi
  if [ "$DOCKER_GB" -gt 0 ] && [ "$DOCKER_GB" -lt 16 ]; then
    echo
    echo "Warning: Docker can use only $DOCKER_GB GB of memory, and the server needs about 16 GB. It may stop"
    echo "with an out-of-memory error. To give Docker more memory:"
    if [ "$IS_MAC" = 1 ]; then
      echo "Docker Desktop > Settings > Resources > Memory."
    elif [ "$IS_WINDOWS" = 1 ]; then
      echo "see 'CPU mode or the Q8_0 text encoder is very slow or crashes on Windows' in README.md."
    else
      echo "close other programs, or use a computer with more memory."
    fi
  fi
  recommend
  # Step 3: the model.
  echo
  echo "Which model do you want to use?"
  echo
  show_presets "$PRESET_REC" "$DEVICE_REC" "$cur"
  if [ "$cur" -gt 0 ]; then pick_preset "$PRESET_COUNT" "$cur"; else pick_preset "$PRESET_COUNT" "$PRESET_REC"; fi
  p=$(preset "$CHOICE")
  # Step 3b: the split, now that the model is known. A split that puts every part on one GPU is that GPU.
  if [ "$DEVICE_REC" = gpu ]; then
    if [ "${SPLIT:-0}" = 1 ]; then split_gpus "$p"; else PLACE_TE=$PLACE_IMG; PLACE_DEC=$PLACE_IMG; fi
  fi
  # Write config.yaml as the last step: Ctrl+C before this leaves config.yaml as it was. It is rewritten in place
  # (same file, same owner): the container mounts this file.
  tmp=$(mktemp)
  if ! write_config "$tmp" "$p" || ! cat "$tmp" > config.yaml; then
    rm -f "$tmp"
    echo "Could not write config.yaml." >&2
    exit 1
  fi
  rm -f "$tmp"
  echo
  echo "==> Saved in config.yaml: $(describe "$p")"
  if [ -n "$GPU_NOTE" ]; then
    echo "    and the GPU settings: $GPU_NOTE."
  elif [ "$DEVICE_REC" = cpu ]; then
    echo "    and device: cpu (the server runs on the CPU)."
  fi
}

# --- step 4: build, start, download, load -----------------------------------------------------------------------------
# load_settings: PROFILE, PORT, IMAGE_REPO and IMAGE from config.yaml and .env (created from .env.example).
load_settings() {
  local device
  device=$(sed -nE 's/^[[:space:]]*device[[:space:]]*:[[:space:]]*"?([A-Za-z]+)"?.*/\1/p' config.yaml | head -n1 |
    tr '[:upper:]' '[:lower:]')
  case "$device" in
    gpu|cuda) PROFILE=gpu ;;
    cpu) PROFILE=cpu ;;
    *) echo "config.yaml: 'device' must be gpu or cpu (found '$device')" >&2; exit 1 ;;
  esac
  if [ "$PROFILE" = gpu ] && [ "$OS" = Darwin ]; then
    echo "config.yaml says device: gpu, but a Mac cannot run the GPU version (it needs an NVIDIA GPU)." >&2
    echo "Run $(launcher setup) to choose again." >&2
    exit 1
  fi
  mkdir -p models outputs inputs
  [ -f .env ] || cp .env.example .env
  # server.port in config.yaml (the only "port:" key in the file)
  PORT=$(sed -nE 's/^[[:space:]]+port[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' config.yaml | head -n1)
  PORT=${PORT:-5005}
  # Remember the profile and port so plain `docker compose logs/restart/up` use the same settings.
  { grep -v -E '^(COMPOSE_PROFILES|MCP_PORT)=' .env || true; echo "COMPOSE_PROFILES=$PROFILE"; echo "MCP_PORT=$PORT"; } \
    > .env.tmp && mv .env.tmp .env
  IMAGE_REPO=$(sed -nE 's/^[[:space:]]*IMAGE_REPO[[:space:]]*=[[:space:]]*([^[:space:]#]+).*/\1/p' .env | head -n1)
  IMAGE="${IMAGE_REPO:-imagegen-mcp}:$PROFILE"
}
server_running() { docker ps --filter 'name=^imagegen-mcp$' --format '{{.Names}}' 2>/dev/null | grep -q .; }

# build_image FORCE: step 4a. Builds the image (or pulls it with IMAGE_REPO) when it is missing, when FORCE is 1 or
# after an update changed the server code.
build_image() {
  local again=
  if [ -f "$BUILD_MARK" ]; then set -- 1; fi
  if [ "$1" != 1 ] && docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> Using the image server you already built."
    return 0
  fi
  if [ -n "$IMAGE_REPO" ]; then
    echo "==> Downloading the image server ($IMAGE)..."
    if docker compose --profile "$PROFILE" pull; then rm -f "$BUILD_MARK"; return 0; fi
    echo "The download failed (details are above). Check your internet connection, then run $LAUNCHER again." >&2
    return 1
  fi
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> Building the image server again (10-30 minutes)"
  else
    echo "==> Building the image server (first time only, 10-30 minutes)"
  fi
  echo "    Docker's build output follows. Leave this window open until it finishes."
  if docker compose --profile "$PROFILE" build; then
    rm -f "$BUILD_MARK"
    echo "    The server is built."
    return 0
  fi
  {
    echo
    echo "The build failed (details are above). The usual causes:"
    echo "  - No internet connection: check it."
    echo "  - The disk is full: free some space."
    echo "  - Not enough memory to compile: set BUILD_JOBS=4 (or 2) in .env."
    echo "Then run $LAUNCHER again. The parts that finished are kept, so it continues where it stopped."
  } >&2
  return 1
}
# explain_up_error OUTPUT: why `docker compose up` failed, and what to do.
explain_up_error() {
  printf '%s\n' "$1" | awk 'NF' | tail -n 5 >&2
  case "$1" in
    *"port is already allocated"*|*"address already in use"*|*"Only one usage of each socket address"*)
      echo "Port $PORT is used by another program. Close that program, or set another port in config.yaml" >&2
      echo "(server: port:), then run $LAUNCHER again." >&2 ;;
    *"could not select device driver"*|*"nvidia-container"*|*"capabilities: [[gpu]]"*)
      echo "Docker cannot reach the NVIDIA GPU. Install the NVIDIA Container Toolkit:" >&2
      echo "https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html" >&2
      echo "then restart Docker and run $LAUNCHER again." >&2 ;;
    *)
      echo "The server could not be started. Run $LAUNCHER again; if it fails again, the details are in:" >&2
      echo "    docker compose logs --tail 80" >&2 ;;
  esac
}
# explain_server_error MESSAGE: the server stopped while starting.
explain_server_error() {
  echo "The server could not start: $(printf '%s' "$1" | cut -c1-400)" >&2
  case "$1" in
    *"out of memory"*|*"Out of memory"*|*"OutOfMemory"*|*cudaMalloc*|*"failed to allocate"*)
      echo "The model does not fit in memory. Run $(launcher setup) and choose a smaller model (Turbo needs the least)." >&2 ;;
    *"driver version is insufficient"*|*"CUDA driver"*)
      echo "Update the NVIDIA driver to 570 or newer, then run $LAUNCHER again." >&2 ;;
    *"no CUDA device is visible"*)
      echo "Docker cannot reach the NVIDIA GPU. Update the NVIDIA driver and Docker, restart the computer," >&2
      echo "then run $LAUNCHER again." >&2 ;;
    *"disk space"*)
      echo "Free some disk space, then run $LAUNCHER again. The download continues where it stopped." >&2 ;;
    *http*|*HTTP*|*onnect*|*download*)
      echo "The model download failed. Check your internet connection, then run $LAUNCHER again." >&2
      echo "The download continues where it stopped." >&2 ;;
  esac
  echo "Details: docker compose logs --tail 80" >&2
}
# wait_ready: steps 4b and 4c. Shows the download and the model loading until the server is ready.
wait_ready() {
  local body state dl total pct err where line= said=
  while :; do
    body=$(curl -fsS "http://localhost:${PORT}/api/status" 2>/dev/null || true)
    if [ -n "$body" ]; then
      state=$(printf '%s' "$body" | sed -nE 's/^\{"state":"([a-z]+)".*/\1/p')
      case "$state" in
        downloading)
          dl=$(printf '%s' "$body" | sed -nE 's/.*"download":\{"state":"([a-z]+)".*/\1/p')
          if [ "$dl" = checking ] && [ -z "$said" ]; then
            echo "==> Checking the model files..."; said=checking
          elif [ "$dl" = downloading ]; then
            dl=$(printf '%s' "$body" | sed -nE 's/.*"downloaded_gb":([0-9.]+).*/\1/p')
            total=$(printf '%s' "$body" | sed -nE 's/.*"total_gb":([0-9.]+).*/\1/p')
            pct=$(printf '%s' "$body" | sed -nE 's/.*"download":\{[^}]*"percent":([0-9.]+).*/\1/p')
            if [ "$said" != downloading ]; then
              echo "==> Downloading the model files (first time only, or after changing the model): $total GB"
              said=downloading
            fi
            line="    $dl of $total GB (${pct:-0}%)"
            printf '\r%s   ' "$line"
          fi ;;
        loading)
          if [ "$said" != loading ]; then
            if [ -n "$line" ]; then echo; line=; fi
            where=$(device_text)
            case "$where" in
              CPU) echo "==> Loading the model on the CPU..." ;;
              "image model"*) echo "==> Loading the model ($where)..." ;;
              *) echo "==> Loading the model on $where..." ;;
            esac
            said=loading
          fi ;;
        ready)
          if [ -n "$line" ]; then echo; fi
          return 0 ;;
        error)
          if [ -n "$line" ]; then echo; fi
          err=$(printf '%s' "$body" | sed -nE 's/^\{"state":"error","error":"(([^"\\]|\\.)*)".*/\1/p' |
            sed 's/\\n/ /g; s/\\"/"/g')
          explain_server_error "$err"
          return 1 ;;
      esac
    fi
    if ! server_running; then
      if [ -n "$line" ]; then echo; fi
      echo "The server stopped while starting. Details: docker compose logs --tail 80" >&2
      return 1
    fi
    sleep 2
  done
}
show_ready() {
  echo
  echo "Ready. Add this address to your AI app as an MCP server:"
  echo "    http://localhost:$PORT/mcp"
  echo "Status page: http://localhost:$PORT (open it in a browser)"
  echo "The server runs in the background, so you can close this window. It starts again with Docker."
  echo "To change the settings, run $(launcher setup). To stop the server, run $(launcher stop)."
}
# start_server ask|restart BUILD: step 4. With "ask", a running server is restarted only when the person wants to.
start_server() {
  local out
  load_settings
  detect
  if [ "$1" = ask ] && server_running && interactive; then
    echo
    echo "The server is already running."
    if ! yes_no "Restart it? (Only needed after you changed config.yaml by hand.)" n; then
      wait_ready || exit 1
      show_ready
      return 0
    fi
  fi
  build_image "${2:-0}" || exit 1
  echo "==> Starting the server..."
  docker compose --profile gpu --profile cpu down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f imagegen-mcp >/dev/null 2>&1 || true
  if ! out=$(docker compose --profile "$PROFILE" up -d --no-build 2>&1); then
    if ! server_running; then explain_up_error "$out"; exit 1; fi
  fi
  wait_ready || exit 1
  show_ready
}

# --- update -----------------------------------------------------------------------------------------------------------
# run_update: install the latest version with git. config.yaml, .env, the models and the images are never touched.
run_update() {
  local out branch behind ahead old changed them=them
  if ! command -v git >/dev/null 2>&1; then
    echo "Git is not installed, so this copy cannot update itself."
    echo "Download the latest version from $REPO_URL"
    echo "and copy your config.yaml, .env and models folder into it."
    return 0
  fi
  export GIT_TERMINAL_PROMPT=0   # fail instead of asking for a password
  # --show-prefix is empty only when this folder is the top of a git copy.
  if ! out=$(git rev-parse --show-prefix 2>&1); then
    case "$out" in
      *"not a git repository"*) out=none ;;
      *) printf '%s\n' "$out" | head -n1; return 0 ;;   # for example "detected dubious ownership"
    esac
  fi
  if [ -n "$out" ]; then
    echo "This folder is not a git copy (it was probably downloaded as a ZIP), so it cannot update itself."
    echo "Download the latest version from $REPO_URL"
    echo "and copy your config.yaml, .env and models folder into it."
    return 0
  fi
  if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ "$branch" = HEAD ]; then echo "This copy is not on a branch, so it cannot be updated."; return 0; fi
    echo "This copy is on branch '$branch', which does not follow a branch on GitHub, so it cannot be updated."
    return 0
  fi
  echo "==> Checking for updates..."
  if ! git fetch --quiet >/dev/null 2>&1; then
    echo "Could not reach GitHub. Check your internet connection, then run $LAUNCHER again."
    return 0
  fi
  behind=$(git rev-list --count 'HEAD..@{u}' 2>/dev/null) || behind=0
  ahead=$(git rev-list --count '@{u}..HEAD' 2>/dev/null) || ahead=0
  if [ "$behind" = 0 ]; then echo "You already have the latest version."; return 0; fi
  if [ "$behind" = 1 ]; then echo "1 update is available:"; them=it; else echo "$behind updates are available:"; fi
  git --no-pager log --oneline --no-decorate --reverse 'HEAD..@{u}' 2>/dev/null | sed -n '1,15s/^/    /p' || true
  if [ "$behind" -gt 15 ]; then echo "    ... and $((behind - 15)) more"; fi
  if ! yes_no "Install $them now?" y; then return 0; fi
  old=$(git rev-parse HEAD)
  if [ "$ahead" != 0 ] || ! out=$(git merge --ff-only --quiet '@{u}' 2>&1); then
    changed=$(git --no-pager status --porcelain --untracked-files=no 2>/dev/null | sed 's/^.. //' || true)
    echo
    echo "The update cannot be installed because this copy was changed on this computer:"
    if [ -n "$changed" ]; then printf '%s\n' "$changed" | sed -n '1,15s/^/    /p'; fi
    if [ "$ahead" != 0 ]; then echo "    $ahead commit(s) made on this computer"; fi
    if [ -z "$changed" ] && [ "$ahead" = 0 ]; then printf '%s\n' "$out" | awk 'NF && n < 6 { print "    " $0; n++ }'; fi
    echo "Your settings (config.yaml, .env), the models and your images are not affected."
    echo
    echo "  1) Cancel the update and keep the changes"
    echo "  2) Discard the changes and install the update"
    read_choice 2 1
    if [ "$CHOICE" = 1 ]; then echo "Nothing was changed."; return 0; fi
    # Keep a copy for people who know git: the changed files in a stash, the old version in a branch.
    if [ -n "$changed" ]; then git stash push --quiet -m "changes before update" >/dev/null 2>&1 || true; fi
    git branch -f before-update "$old" >/dev/null 2>&1 || true
    if ! out=$(git reset --hard --quiet '@{u}' 2>&1); then
      echo "The update failed: $(printf '%s\n' "$out" | awk 'NF { print; exit }')" >&2
      return 1
    fi
    echo "    The changes were discarded. (A copy is kept in git: 'git stash list' and the branch before-update.)"
  fi
  echo
  echo "==> Update installed. Your settings in config.yaml were kept."
  changed=$(git --no-pager diff --name-only "$old" HEAD -- Dockerfile pyproject.toml src docker/patches 2>/dev/null ||
    true)
  if [ -n "$changed" ]; then touch "$BUILD_MARK"; fi
  if [ ! -f config.yaml ]; then echo "Run $(launcher start) to set it up and start it."; return 0; fi
  if [ -n "$changed" ]; then
    echo "    The server itself changed, so it is built again when it starts (10-30 minutes)."
  fi
  if yes_no "Start the new version now?" y; then
    # The new start script (git just replaced it) builds the image if needed and restarts the server.
    exec bash ./start.sh --restart
  fi
  echo "Run $(launcher start) to use the new version."
}
