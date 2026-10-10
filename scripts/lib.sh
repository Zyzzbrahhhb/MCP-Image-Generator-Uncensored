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

# The model choices, the same rows as in scripts/lib.ps1 (tests/test_start_scripts.py checks the files against
# src/imagegen_mcp/models.py): name|variant|quant|text encoder quant|seconds per 1024x1024 image on an RTX 3080 Ti|
# memory for Docker in GB|image model file|its bytes|text encoder file|its bytes
presets() {
  cat <<'EOF'
Best quality|uncensored|Q4_K_M|Q8_0|90|20|diffusion_models/qwen-image-2.1-UC-Q4_K_M.gguf|4604558112|text_encoders/Qwen3VL-8B-Instruct-Q8_0.gguf|8709519456
Standard|uncensored|Q4_K_M|Q4_K_M|90|16|diffusion_models/qwen-image-2.1-UC-Q4_K_M.gguf|4604558112|text_encoders/Qwen3VL-8B-Instruct-Q4_K_M.gguf|5027784800
Turbo|turbo|Q4_K_M|Q4_K_M|12|16|diffusion_models/Qwen-Image-2.1-Turbo-AD-Q4_K.gguf|4201694944|text_encoders/Qwen3VL-8B-Instruct-Q4_K_M.gguf|5027784800
EOF
}
# The files that every model choice needs: path|bytes (under models/).
shared_files() {
  cat <<'EOF'
text_encoders/mmproj-Qwen3VL-8B-Instruct-F16.gguf|1159029824
vae/texture_fix_vae_for_qwen_image_2.1_bf16.safetensors|675509688
background_removal/birefnet-general-lite.onnx|224005088
loras/watermark_remover_v2_qwen.safetensors|79744288
upscalers/4xNomos2_otf_esrgan.safetensors|33467822
EOF
}
# missing_bytes PRESET_LINE: the bytes that this choice still has to download (files that are missing or not complete).
missing_bytes() {
  local path bytes sum=0
  while IFS='|' read -r path bytes; do
    if [ -z "$path" ]; then continue; fi
    if [ ! -f "models/$path" ] || [ "$(wc -c < "models/$path" | tr -d ' ')" != "$bytes" ]; then sum=$((sum + bytes)); fi
  done <<EOF
$(pf "$1" 7)|$(pf "$1" 8)
$(pf "$1" 9)|$(pf "$1" 10)
$(shared_files)
EOF
  echo "$sum"
}
# gpu_need PRESET_LINE: GB of GPU memory for the whole model on one GPU: the image model and the text encoder, the
# decoder (0.7 GB) and the working memory of the largest step (about 4 GB at 1024x1024). See gpu_warnings.
gpu_need() { awk -v d="$(pf "$1" 8)" -v t="$(pf "$1" 10)" 'BEGIN { printf "%d", (d + t) / 1e9 + 0.7 + 4 + 0.5 }'; }
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
      # A key with no value and more-indented lines below it is a block list or map: not changed here.
      if (want) {
        if ($0 ~ /^[ \t]*(#.*)?\r?$/) next
        match($0, /^[ \t]*/); if (RLENGTH > kin) bad = 1
        want = 0
      }
      top()
      if ((s == "" || cur == s) && $0 ~ pat && !has) {
        has = 1; r = $0; sub(pat "[ \t]*", "", r)
        if (r ~ /^(#.*)?\r?$/) { want = 1; match($0, /^[ \t]*/); kin = RLENGTH }
      }
      if (s != "" && $0 ~ ("^" s ":[ \t]*[{[]")) flow = 1
      next
    }
    FNR == 1 { cur = ""; if (flow && !has) bad = 1 }
    { top() }
    has && !done && (s == "" || cur == s) && $0 ~ pat {
      match($0, pat "[ \t]*"); head = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1)
      if (head !~ /[ \t]$/) head = head " "
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
      v = $0; sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t]*#.*/, "", v); gsub(/["\047\r]/, "", v); sub(/[ \t]+$/, "", v)
      print v; exit }
  ' config.yaml 2>/dev/null || true
}
# read_model: sets CUR_PRESET, the number of the model choice in config.yaml (0 = none of them, or no config.yaml),
# CUR_MODEL_TEXT ("uncensored Q4_K_M, text encoder Q8_0") and CUR_CHOICE (the model as a choice line).
read_model() {
  local v q t
  CUR_PRESET=0; CUR_MODEL_TEXT=; CUR_CHOICE=
  if [ ! -f config.yaml ]; then return 0; fi
  v=$(yaml_in model variant | tr '[:upper:]' '[:lower:]'); v=${v:-uncensored}
  q=$(yaml_in model quant | tr '[:lower:]' '[:upper:]' | sed 's/^AD-//'); q=${q:-Q4_K_M}
  case "$q" in Q4|Q4_K) q=Q4_K_M ;; Q5|Q5_K) q=Q5_K_M ;; Q6) q=Q6_K ;; Q8) q=Q8_0 ;; esac
  t=$(yaml_in model text_encoder_quant | tr '[:lower:]' '[:upper:]'); t=${t:-Q4_K_M}
  CUR_MODEL_TEXT="$v $q, text encoder $t"
  CUR_CHOICE="custom|$v|$q|$t||||||"
  CUR_PRESET=$(presets | awk -F'|' -v v="$v" -v q="$q" -v t="$t" '$2 == v && $3 == q && $4 == t { print NR; f = 1; exit }
    END { if (!f) print 0 }')
}
current_model() {
  read_model
  if [ "$CUR_PRESET" -gt 0 ]; then echo "$(pf "$(preset "$CUR_PRESET")" 1) ($CUR_MODEL_TEXT)"
  else echo "custom ($CUR_MODEL_TEXT)"
  fi
}
# read_current: the saved device and GPU places (CUR_DEVICE, CUR_IMG "0" or "0 2", CUR_TE "2", "ram" or "cpu",
# CUR_DEC "2" or "cpu").
read_current() {
  CUR_DEVICE=; CUR_IMG=; CUR_TE=; CUR_DEC=
  if [ ! -f config.yaml ]; then return 0; fi
  CUR_DEVICE=$(sed -nE 's/^device[[:space:]]*:[[:space:]]*"?([A-Za-z]+).*/\1/p' config.yaml | head -n1 |
    tr '[:upper:]' '[:lower:]')
  CUR_IMG=$(yaml_in gpu diffusion | tr -d '[]' | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'); CUR_IMG=${CUR_IMG:-0}
  CUR_TE=$(yaml_in gpu text_encoder); CUR_TE=${CUR_TE:-${CUR_IMG%% *}}
  CUR_DEC=$(yaml_in gpu vae); CUR_DEC=${CUR_DEC:-${CUR_IMG%% *}}
  # offload: {text_encoder: cpu} keeps the text encoder's weights in RAM while it runs on its GPU.
  case "$(yaml_in gpu offload)" in *text_encoder*cpu*) if [ "$CUR_TE" != cpu ]; then CUR_TE=ram; fi ;; esac
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
# largest_gpu: the GPU with the most memory (the first one of those).
largest_gpu() { printf '%s\n' "$GPU_ROWS" | sort -t'|' -k3,3nr -s | head -n1 | cut -d'|' -f1; }
# gpu_fit GB: the model choice that a GPU of this size suits best, and whether all of it fits on the GPU.
gpu_fit() {
  local p cap=$1
  if [ "$1" -lt 20 ]; then cap=$(($1 - 2)); fi
  if [ "$1" -lt 8 ]; then echo "too small"; return 0; fi
  if [ "$1" -lt 12 ]; then echo "Turbo"; return 0; fi
  if [ "$DOCKER_GB" -eq 0 ] || [ "$DOCKER_GB" -ge 20 ]; then p=$(preset 1); else p=$(preset 2); fi
  if [ "$(gpu_need "$p")" -le "$cap" ]; then echo "$(pf "$p" 1), all on the GPU"
  else echo "$(pf "$p" 1), some weights in RAM"
  fi
}
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
# place_label PLACE [IMAGE_GPUS]: "GPU 2 (NVIDIA ..., 12 GB)", "CPU (...)" or, for the text encoder, "RAM, runs on GPU 2".
place_label() {
  local i out=
  if [ "$1" = cpu ]; then echo "CPU ($(cpu_name))"; return 0; fi
  if [ "$1" = ram ]; then echo "RAM, runs on GPU ${2%% *}"; return 0; fi
  for i in $1; do out="${out:+$out + }$(gpu_label "$i")"; done
  echo "$out"
}
# place_short PLACE: "CPU", "RAM", "GPU 2" or "GPU 0 + GPU 2".
place_short() {
  case "$1" in cpu) echo CPU ;; ram) echo RAM ;; *) echo "GPU $(printf '%s' "$1" | sed 's/ / + GPU /g')" ;; esac
}
# parts_text IMG TE DEC: "image model on GPU 0 + GPU 2, text encoder in RAM, image decoder on GPU 2".
parts_text() {
  local te
  case "$2" in ram) te="text encoder in RAM" ;; *) te="text encoder on $(place_short "$2")" ;; esac
  echo "image model on $(place_short "$1"), $te, image decoder on $(place_short "$3")"
}
# device_text: where the server runs, from config.yaml: "CPU", "GPU 2 (NVIDIA GeForce RTX 3080 Ti, 12 GB)" or a split.
# Needs detect for the GPU names.
device_text() {
  local one
  read_current
  if [ "$CUR_DEVICE" = cpu ]; then echo CPU; return 0; fi
  case "$CUR_IMG" in
    *' '*) ;;
    *)
      if [ "$CUR_DEC" = "$CUR_IMG" ] && { [ "$CUR_TE" = "$CUR_IMG" ] || [ "$CUR_TE" = ram ]; }; then
        one=$(gpu_label "$CUR_IMG"); one=${one:-GPU $CUR_IMG}
        if [ "$CUR_TE" = ram ]; then echo "$one, text encoder in RAM"; else echo "$one"; fi
        return 0
      fi ;;
  esac
  parts_text "$CUR_IMG" "$CUR_TE" "$CUR_DEC"
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
# choose_gpus DEFAULT: show the GPUs; with more than one, ask which one to use. Sets SPLIT and PLACE_IMG. A GPU gets
# every part of the model. The last choice, custom load, is set up after the model is chosen (split_gpus), because
# where the parts fit depends on the model's size.
choose_gpus() {
  local idx name gb best mark
  SPLIT=0
  if [ "$GPU_COUNT" -eq 1 ]; then
    echo "    GPU: $GPU_NAME, $VRAM_GB GB ($(gpu_fit "$VRAM_GB"))"; PLACE_IMG=$GPU_INDEX; return 0
  fi
  best=$(largest_gpu)
  echo "    GPUs found:"
  printf '%s\n' "$GPU_ROWS" | while IFS='|' read -r idx name gb; do
    if [ "$idx" = "$best" ]; then mark="  <- recommended"; else mark=; fi
    printf '      %-38s %s%s\n' "$idx) $name, $gb GB" "$(gpu_fit "$gb")" "$mark"
  done
  echo "      $GPU_COUNT) Custom load (multi-GPU and CPU)"
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
          echo "    The custom load is set up after you choose the model."
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
  if [ "$IS_MAC" = 1 ] || [ "$GPU_COUNT" -gt 0 ]; then
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
# show_presets RECOMMENDED cpu|gpu CURRENT [CUSTOM]: print the model choices (CURRENT 0 = no current model). With
# CUSTOM (the text of a model that is none of the choices), a last line offers to keep it.
show_presets() {
  local i=0 p dl mem tm mark
  if [ "$2" = cpu ]; then echo "    Choice          Download     Memory       Time per image"
  else echo "    Choice          Download     GPU memory   Time per image"
  fi
  while IFS= read -r p; do
    i=$((i + 1)); mark=
    dl=$(missing_bytes "$p")
    if [ "$dl" = 0 ]; then dl=downloaded; else dl=$(awk -v b="$dl" 'BEGIN { printf "%.1f GB", b / 1e9 }'); fi
    if [ "$2" = cpu ]; then mem="$(pf "$p" 6) GB"; tm=minutes; else mem="$(gpu_need "$p") GB"; tm="~$(pf "$p" 5) s"; fi
    if [ "$i" = "$3" ] && [ "$i" = "$1" ]; then mark="  <- current, recommended"
    elif [ "$i" = "$3" ]; then mark="  <- current"
    elif [ "$i" = "$1" ]; then mark="  <- recommended"
    fi
    printf ' %d) %-15s %-12s %-12s %s%s\n' "$i" "$(pf "$p" 1)" "$dl" "$mem" "$tm" "$mark"
  done <<EOF
$(presets)
EOF
  if [ -n "${4:-}" ]; then echo " $((PRESET_COUNT + 1))) Keep the current model: $4  <- current"; fi
  echo
  if [ "$2" = cpu ]; then
    echo " Memory: what Docker needs. On the CPU, each image takes several minutes."
  else
    echo " GPU memory: the whole model on the GPU. A smaller GPU keeps some weights in RAM, at the same speed."
    echo " Times: one 1024x1024 image on an RTX 3080 Ti."
  fi
  echo " 1 and 2 use the uncensored model. $TURBO uses the official Turbo model: much faster, weaker at small text."
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
image_gb() {
  if [ -n "$(pf "$1" 8)" ]; then awk -v b="$(pf "$1" 8)" 'BEGIN { printf "%.1f", b / 1e9 }'; return 0; fi
  case "$(pf "$1" 3)" in Q6_K) echo 5.9 ;; Q8_0) echo 7.6 ;; *) case "$(pf "$1" 2)" in turbo) echo 4.2 ;; *) echo 4.6 ;; esac ;; esac
}
encoder_gb() {
  if [ -n "$(pf "$1" 10)" ]; then awk -v b="$(pf "$1" 10)" 'BEGIN { printf "%.1f", b / 1e9 }'; return 0; fi
  case "$(pf "$1" 4)" in Q8_0) echo 8.7 ;; F16) echo 16.4 ;; *) echo 5.0 ;; esac
}
DECODER_GB=0.7
# part_default PLACE image|te|dec HOST: the menu number for a saved place. HOST is the first GPU of the image model.
# Without a valid saved place: the first GPU for the image model; RAM for the text encoder on a GPU under 20 GB (else
# that GPU); the image model's GPU for the image decoder.
part_default() {
  case "$2:$1" in
    image:*' '*) echo "$GPU_COUNT"; return 0 ;;
    te:ram) echo "$GPU_COUNT"; return 0 ;;
    te:cpu) echo $((GPU_COUNT + 1)); return 0 ;;
    dec:cpu) echo "$GPU_COUNT"; return 0 ;;
    *:*' '*|*:cpu|*:ram|*:) ;;
    *) if [ -n "$(gpu_gb "$1")" ]; then echo "$1"; return 0; fi ;;
  esac
  case "$2" in
    image) first_gpu ;;
    te) if [ "$(gpu_gb "$3")" -lt 20 ]; then echo "$GPU_COUNT"; else echo "$3"; fi ;;
    dec) echo "$3" ;;
  esac
}
# place_part NAME GB image|te|dec DEFAULT HOST: ask where one part runs. Sets PLACE: a GPU number, several (image
# model), "ram" (text encoder: weights in RAM, runs on HOST) or "cpu".
place_part() {
  local idx name gb n=$GPU_COUNT rec=
  echo
  echo "$1 ($2 GB): where should it run?"
  printf '%s\n' "$GPU_ROWS" | while IFS='|' read -r idx name gb; do echo "  $idx) GPU $idx: $name, $gb GB"; done
  case "$3" in
    image) echo "  $n) Several GPUs (split it)" ;;
    te)
      if [ "$(gpu_gb "$5")" -lt 20 ]; then rec="  <- recommended"; fi
      echo "  $n) RAM: the weights stay in RAM, it runs on GPU $5$rec"
      echo "  $((n + 1))) CPU: $(cpu_name) (slow)" ;;
    dec) echo "  $n) CPU: $(cpu_name) (slow)" ;;
  esac
  while :; do
    ask "Type a number and press Enter" "$4"
    case "$ANSWER" in
      *[!0-9]*|'') ;;
      *)
        if [ -n "$(gpu_gb "$ANSWER")" ]; then PLACE=$ANSWER; return 0; fi
        case "$3:$((ANSWER - n))" in
          image:0) pick_gpus; return 0 ;;
          te:0) PLACE=ram; return 0 ;;
          te:1|dec:0) PLACE=cpu; return 0 ;;
        esac ;;
    esac
    if [ "$3" = te ]; then echo "Please type a number from 0 to $((n + 1))."; else echo "Please type a number from 0 to $n."; fi
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
# gpu_warnings IMG TE DEC PRESET_LINE: a line for each GPU that may run out of memory with these places (TE "ram":
# its weights in RAM, it runs on the first GPU of IMG). A GPU needs its model files plus the working memory of the
# largest step that runs on it (the steps run one after another): the image model about 3 GB, the image decoder about
# 4 GB (1024x1024), the text encoder 1.5-2.2 GB. When the files do not fit, the engine's auto-fit keeps the weights of
# the text encoder and the decoder in RAM by itself (about 0.2 GB each on the GPU), at the same speed. The limit is the
# memory minus 2 GB. Measured on a 12 GB GPU: Turbo with every part on the GPU runs in 11.5 s (auto-fit moved the text
# encoder and decoder weights to RAM); a 5 GB image model makes the decoder fall back to tiles.
gpu_warnings() {
  local ig eg
  ig=$(image_gb "$4"); eg=$(encoder_gb "$4")
  printf '%s\n' "$GPU_ROWS" | awk -F'|' -v img="$1" -v te="$2" -v dec="$3" -v ig="$ig" -v eg="$eg" '
    { n = split(img, a, " "); files = 0; fit = 0; work = 0
      for (j = 1; j <= n; j++) if (a[j] == $1) { files += ig / n; fit += ig / n; work = 3 }
      if (te == "ram" && a[1] == $1) { files += 0.2; fit += 0.2; if (work < 1.5) work = 1.5 }
      if (te == $1) { files += eg; fit += 0.2; if (work < 2.2) work = 2.2 }
      if (dec == $1) { files += 0.7; fit += 0.2; if (work < 4) work = 4 }
      need = files + work
      if (need > $3 - 2) need = fit + work   # auto-fit keeps the text encoder and decoder weights in RAM
      if (files > 0 && need > $3 - 2)
        printf "    GPU %s (%s, %s GB) may run out of memory: its parts need about %d GB.\n", $1, $2, $3, int(need + 0.5) }'
}
# show_warnings IMG TE DEC PRESET_LINE: print the memory warnings, if any. True when there were some.
show_warnings() {
  local warn
  warn=$(gpu_warnings "$@")
  if [ -z "$warn" ]; then return 1; fi
  echo
  echo "$warn"
  echo "    The server then works more slowly (it moves parts to RAM) or stops with an out-of-memory error."
  return 0
}
# split_gpus PRESET_LINE: the custom load. Place the image model, the text encoder and the image decoder one by one,
# then show all three with a warning for any GPU that may run out of memory, and confirm or start over.
# Sets PLACE_IMG, PLACE_TE and PLACE_DEC.
split_gpus() {
  local img te dec ig eg
  ig=$(image_gb "$1"); eg=$(encoder_gb "$1")
  echo
  echo "Custom load for $(pf "$1" 1): choose where each part of the model runs."
  while :; do
    place_part "Image model" "$ig" image "$(part_default "$CUR_IMG" image)"; img=$PLACE
    place_part "Text encoder" "$eg" te "$(part_default "$CUR_TE" te "${img%% *}")" "${img%% *}"; te=$PLACE
    place_part "Image decoder" "$DECODER_GB" dec "$(part_default "$CUR_DEC" dec "${img%% *}")"; dec=$PLACE
    echo
    echo "Your custom load:"
    printf '    %-24s %s\n' "Image model ($ig GB):" "$(place_label "$img")"
    printf '    %-24s %s\n' "Text encoder ($eg GB):" "$(place_label "$te" "$img")"
    printf '    %-24s %s\n' "Image decoder ($DECODER_GB GB):" "$(place_label "$dec")"
    show_warnings "$img" "$te" "$dec" "$1" || true
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
  local i gb te used caps= limits= cache=auto offload=auto
  GPU_NOTE=
  if [ -f config.yaml ]; then cp config.yaml "$1"; else cp config.example.yaml "$1"; fi || return 1
  set_yaml "$1" device "$DEVICE_REC" || return 1
  if [ "$DEVICE_REC" = gpu ]; then
    used=$(printf '%s\n' $PLACE_IMG $PLACE_TE $PLACE_DEC | grep -v '^cpu$' | grep -v '^ram$' | sort -un | tr '\n' ' ')
    for i in $used; do
      gb=$(gpu_gb "$i")
      if [ "${gb:-0}" -lt 20 ]; then
        caps="${caps:+$caps, }$i: $((gb - 2))"; limits="${limits:+$limits, }GPU $i limited to $((gb - 2)) GB"
      fi
    done
    if [ -n "$caps" ]; then cache=q8_0; fi
    # Text encoder in RAM: it runs on the image model's (first) GPU, its weights stay in RAM. Otherwise auto: the
    # engine keeps weights in RAM only when they do not fit.
    te=$PLACE_TE
    if [ "$PLACE_TE" = ram ]; then te=${PLACE_IMG%% *}; offload="{text_encoder: cpu}"; fi
    set_yaml "$1" diffusion "[$(printf '%s' "$PLACE_IMG" | sed 's/ /, /g')]" gpu &&
      set_yaml "$1" text_encoder "$te" gpu && set_yaml "$1" vae "$PLACE_DEC" gpu &&
      set_yaml "$1" max_vram_gb "{$caps}" gpu && set_yaml "$1" offload "$offload" gpu &&
      set_yaml "$1" prefix_cache_type "$cache" generation || return 1
    if [ "$PLACE_IMG" = "$PLACE_DEC" ] && { [ "$PLACE_TE" = "$PLACE_IMG" ] || [ "$PLACE_TE" = ram ]; } &&
       [ "$PLACE_IMG" = "${PLACE_IMG%% *}" ]; then
      gb=$(gpu_gb "$PLACE_IMG")
      GPU_NOTE="GPU $PLACE_IMG"
      if [ "$gb" -lt 20 ]; then GPU_NOTE="$GPU_NOTE (limited to $((gb - 2)) GB)"; fi
      if [ "$PLACE_TE" = ram ]; then GPU_NOTE="$GPU_NOTE, text encoder in RAM"; fi
    else
      GPU_NOTE="$(parts_text "$PLACE_IMG" "$PLACE_TE" "$PLACE_DEC")${limits:+ ($limits)}"
    fi
  fi
  # A custom model (kept in the setup) stays as it is in config.yaml.
  if [ "$(pf "$2" 1)" = custom ]; then return 0; fi
  set_model "$1" "$2"
}

# --- steps 2 to 3b: the setup -----------------------------------------------------------------------------------------
# Asks where the server runs and which model it uses and saves the answers in config.yaml. When config.yaml exists,
# its settings are the defaults, so Enter keeps them.
run_setup() {
  local p tmp cur total custom= gpu_default=
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
    gpu_default=$(largest_gpu)
    if [ "$CUR_DEVICE" = gpu ]; then
      if [ "$CUR_IMG" != "$CUR_TE" ] || [ "$CUR_TE" != "$CUR_DEC" ]; then gpu_default=$GPU_COUNT   # a custom load
      elif [ -n "$(gpu_gb "$CUR_IMG")" ]; then gpu_default=$CUR_IMG
      fi
    fi
    total=$(printf '%s\n' "$GPU_ROWS" | awk -F'|' '{ s += $3 } END { print s + 0 }')
    while :; do
      choose_gpus "$gpu_default"
      if [ "$VRAM_GB" -ge 8 ] || [ "$GPU_COUNT" -eq 1 ] || [ "$total" -lt 8 ]; then break; fi
      echo
      echo "That GPU has only $VRAM_GB GB of memory (8 GB or more is needed). Choose another GPU or the split."
      gpu_default=$GPU_COUNT
    done
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
  # Step 3: the model. On one GPU, the same memory check as for a split.
  while :; do
    echo
    if [ "$DEVICE_REC" = cpu ]; then echo "Which model do you want to use? (on the CPU)"
    elif [ "${SPLIT:-0}" = 1 ]; then echo "Which model do you want to use? (custom load)"
    else echo "Which model do you want to use? (on GPU $PLACE_IMG: $GPU_NAME, $VRAM_GB GB)"
    fi
    echo
    # A model that is none of the choices (set by hand in config.yaml) is offered as one more choice.
    if [ -f config.yaml ] && [ "$cur" = 0 ]; then custom="custom ($CUR_MODEL_TEXT)"; fi
    show_presets "$PRESET_REC" "$DEVICE_REC" "$cur" "$custom"
    if [ -n "$custom" ]; then pick_preset $((PRESET_COUNT + 1)) $((PRESET_COUNT + 1))
    elif [ "$cur" -gt 0 ]; then pick_preset "$PRESET_COUNT" "$cur"
    else pick_preset "$PRESET_COUNT" "$PRESET_REC"
    fi
    if [ "$CHOICE" -gt "$PRESET_COUNT" ]; then p=$CUR_CHOICE; else p=$(preset "$CHOICE"); fi
    if [ "$DEVICE_REC" != gpu ] || [ "${SPLIT:-0}" = 1 ]; then break; fi
    PLACE_TE=$PLACE_IMG; PLACE_DEC=$PLACE_IMG
    if ! show_warnings "$PLACE_IMG" "$PLACE_TE" "$PLACE_DEC" "$p"; then break; fi
    echo
    echo "  1) Confirm"
    echo "  2) Choose another model"
    read_choice 2 1
    if [ "$CHOICE" = 1 ]; then break; fi
  done
  # Step 3b: the custom load, now that the model is known.
  if [ "$DEVICE_REC" = gpu ] && [ "${SPLIT:-0}" = 1 ]; then split_gpus "$p"; fi
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
# installed: true when the first install has finished: the image of the server is there (built or downloaded).
installed() { load_settings; docker image inspect "$IMAGE" >/dev/null 2>&1; }
# server_running: true when the container runs (one that keeps restarting after a crash does not count).
server_running() {
  docker ps --filter 'name=^imagegen-mcp$' --filter status=running --format '{{.Names}}' 2>/dev/null | grep -q .
}
# container_state: "STATUS RESTARTS" of the container (empty when there is no container).
container_state() { docker inspect -f '{{.State.Status}} {{.RestartCount}}' imagegen-mcp 2>/dev/null | tr -d '\r' || true; }
# server_status: the server's answer to /api/status (empty when it does not answer).
server_status() { curl -fsS --max-time 5 "http://localhost:${PORT}/api/status" 2>/dev/null || true; }
# show_stopped: the server stopped while starting; show the end of its log (a config error is named there).
show_stopped() {
  {
    echo "The server stopped while starting. The end of its log:"
    docker logs --tail 12 imagegen-mcp 2>&1 | awk 'NF { print "    " $0 }' | tail -n 12 || true
    echo "If you changed config.yaml by hand, correct the setting named above or run $(launcher setup). Then run $LAUNCHER again."
    echo "Details: docker compose logs --tail 80"
  } >&2
}

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
      case "$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)" in
        *"Docker Desktop"*)
          echo "Docker cannot reach the NVIDIA GPU. Update the NVIDIA driver (570 or newer), restart the computer," >&2
          echo "then run $LAUNCHER again." >&2 ;;
        *)
          echo "Docker cannot reach the NVIDIA GPU. Install the NVIDIA Container Toolkit:" >&2
          echo "https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html" >&2
          echo "then restart Docker and run $LAUNCHER again." >&2 ;;
      esac ;;
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
  local body state dl total pct err where cs st rc restarts line= said= silent=0
  cs=$(container_state); restarts=${cs##* }
  case "$restarts" in ''|*[!0-9]*) restarts=0 ;; esac
  while :; do
    body=$(server_status)
    if [ -z "$body" ]; then
      # No answer: the server is still starting, or its container stopped or restarted after a crash.
      cs=$(container_state); st=${cs%% *}; rc=${cs##* }
      case "$rc" in ''|*[!0-9]*) rc=0 ;; esac
      if [ -z "$cs" ] || [ "$st" != running ] || [ "$rc" -gt "$restarts" ]; then
        if [ -n "$line" ]; then echo; fi
        show_stopped
        return 1
      fi
      silent=$((silent + 1))
      if [ "$silent" = 45 ]; then echo "    (still waiting for the server to answer on port $PORT)"; fi
    else
      silent=0
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
# start_server ask|restart BUILD: step 4. With "ask", a running server is restarted only when the person wants to,
# or when it must be: after an update that changed the server, with --build, or when it stopped with an error.
start_server() {
  local out st
  load_settings
  detect
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is needed to follow the start. Install it (for example: sudo apt install curl), then run $LAUNCHER again." >&2
    exit 1
  fi
  if [ "$1" = ask ] && server_running; then
    st=$(server_status | sed -nE 's/^\{"state":"([a-z]+)".*/\1/p' || true)
    if [ -f "$BUILD_MARK" ]; then
      echo "==> An update changed the server, so it is built again and restarted."
    elif [ "${2:-0}" = 1 ]; then
      :
    elif [ "$st" = error ]; then
      echo "==> The server stopped with an error, so it is started again."
    elif interactive; then
      echo
      echo "The server is already running."
      if ! yes_no "Restart it? (Only needed after you changed config.yaml by hand.)" n; then
        wait_ready || exit 1
        show_ready
        return 0
      fi
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
# A change in these paths needs a new image (see .dockerignore; docker-compose.yml has the build settings).
IMAGE_PATHS="Dockerfile pyproject.toml src docker/patches docker-compose.yml .dockerignore"
IMAGE_PATTERN='^(Dockerfile|pyproject\.toml|docker-compose\.yml|\.dockerignore)$|^(src|docker/patches)/'
# run_update: install the latest version with git. config.yaml, .env, the models and the images are never touched.
run_update() {
  local out branch behind diverged ahead old changed inway f stamp kept= moved= failed=0 need_build=0 start= them=them
  # A ZIP download has no .git folder. Check that first: git may be missing, or a stub that opens an installer.
  if [ ! -e .git ]; then
    echo "This folder is not a git copy (it was probably downloaded as a ZIP), so it cannot update itself."
    echo "Download the latest version from $REPO_URL"
    echo "and copy your config.yaml, .env and models folder into it."
    return 0
  fi
  if ! command -v git >/dev/null 2>&1 || ! git --version >/dev/null 2>&1; then
    echo "Git is not installed, so this copy cannot update itself. Install Git (on a Mac: xcode-select --install),"
    echo "then run $LAUNCHER again."
    return 0
  fi
  export GIT_TERMINAL_PROMPT=0   # fail instead of asking for a password
  if ! out=$(git rev-parse --show-toplevel 2>&1); then
    # For example "detected dubious ownership": git's next lines name the command that fixes it.
    echo "Git reported an error:"
    printf '%s\n' "$out" | awk 'NF { print "    " $0 }'
    return 0
  fi
  if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ "$branch" = HEAD ]; then echo "This copy is not on a branch, so it cannot be updated."; return 0; fi
    echo "This copy is on branch '$branch', which does not follow a branch on GitHub, so it cannot be updated."
    return 0
  fi
  echo "==> Checking for updates..."
  if ! out=$(git fetch --quiet 2>&1); then
    echo "Could not get the updates: $(printf '%s\n' "$out" | awk 'NF { print; exit }')"
    echo "Check your internet connection, then run $LAUNCHER again."
    return 0
  fi
  behind=$(git rev-list --count 'HEAD..@{u}' 2>/dev/null) || behind=0
  diverged=$(git rev-list --count '@{u}..HEAD' 2>/dev/null) || diverged=0
  # Commits of this copy whose changes are not on GitHub (old commits of a rewritten GitHub history do not count).
  ahead=$(git rev-list --count --cherry-pick --right-only '@{u}...HEAD' 2>/dev/null) || ahead=0
  if [ "$behind" = 0 ]; then echo "You already have the latest version."; return 0; fi
  if [ "$behind" = 1 ]; then echo "1 update is available:"; them=it; else echo "$behind updates are available:"; fi
  git --no-pager log --oneline --no-decorate --reverse 'HEAD..@{u}' 2>/dev/null | sed -n '1,15s/^/    /p' || true
  if [ "$behind" -gt 15 ]; then echo "    ... and $((behind - 15)) more"; fi
  if ! yes_no "Install $them now?" y; then return 0; fi
  old=$(git rev-parse HEAD)
  if [ "$diverged" != 0 ] || ! out=$(git merge --ff-only --quiet '@{u}' 2>&1); then
    changed=$(git --no-pager status --porcelain --untracked-files=no 2>/dev/null | sed 's/^.. //' || true)
    # Files of this computer where the update adds a file: git would delete them, so they are renamed first.
    inway=$(git --no-pager diff --name-only --diff-filter=A HEAD '@{u}' 2>/dev/null | while IFS= read -r f; do
      if [ -e "$f" ] && ! printf '%s\n' "$changed" | grep -qxF -- "$f"; then printf '%s\n' "$f"; fi
    done || true)
    if [ "$ahead" = 0 ] && [ -z "$changed" ] && [ -z "$inway" ]; then
      # Nothing of this computer is lost: the history on GitHub was rewritten. Take it as it is.
      echo "The version on GitHub was rewritten, so it replaces this copy."
    else
      echo
      echo "The update cannot be installed because this copy was changed on this computer:"
      if [ -n "$changed" ]; then printf '%s\n' "$changed" | sed -n '1,15s/^/    /p'; fi
      if [ -n "$inway" ]; then printf '%s\n' "$inway" | sed -n '1,15s/.*/    & (your file, where the update adds one)/p'; fi
      if [ "$ahead" != 0 ]; then echo "    $ahead commit(s) that are not on GitHub"; fi
      echo "Your settings (config.yaml, .env), the models and your images are not affected."
      echo
      echo "  1) Cancel the update and keep the changes"
      echo "  2) Discard the changes and install the update"
      read_choice 2 1
      if [ "$CHOICE" = 1 ]; then echo "Nothing was changed."; return 0; fi
    fi
    stamp=$(date +%Y%m%d-%H%M%S)
    # A copy for people who know git: the changed files in a stash, the old version in a branch of its own.
    # The name and email let the stash work where git has no identity set (common on new computers).
    if [ -n "$changed" ]; then
      if ! out=$(git -c user.name="Image Gen MCP" -c user.email=update@localhost stash push --quiet \
          -m "changes before update $stamp" 2>&1); then
        echo "The update failed: no copy of the changes could be kept ($(printf '%s\n' "$out" | awk 'NF { print; exit }'))." >&2
        echo "Nothing was changed."
        return 1
      fi
      kept="'git stash list'"
      if printf '%s\n' "$changed" | grep -Eq "$IMAGE_PATTERN"; then need_build=1; fi
    fi
    if git branch "before-update-$stamp" "$old" >/dev/null 2>&1; then
      kept="${kept:+$kept and }the branch before-update-$stamp"
    fi
    if [ -n "$inway" ]; then
      while IFS= read -r f; do
        mv -f -- "$f" "$f.before-update"; moved="${moved:+$moved, }$f.before-update"
      done <<EOF
$inway
EOF
    fi
    # Settings files survive even when a commit of this copy had added them to git.
    for f in config.yaml .env docker-compose.override.yml; do
      if [ -f "$f" ]; then cp -p "$f" "$f.update-backup"; fi
    done
    if ! out=$(git reset --hard --quiet '@{u}' 2>&1); then failed=1; fi
    for f in config.yaml .env docker-compose.override.yml; do
      if [ -f "$f.update-backup" ]; then
        if [ -e "$f" ]; then rm -f "$f.update-backup"; else mv -f "$f.update-backup" "$f"; fi
      fi
    done
    if [ "$failed" = 1 ]; then
      echo "The update failed: $(printf '%s\n' "$out" | awk 'NF { print; exit }')" >&2
      return 1
    fi
    if [ -n "$kept" ]; then echo "    The old version is kept in git: $kept."; fi
    if [ -n "$moved" ]; then echo "    Your files were renamed: $moved"; fi
  fi
  echo
  echo "==> Update installed. Your settings in config.yaml were kept."
  # shellcheck disable=SC2086  # IMAGE_PATHS is a list of paths
  if [ -n "$(git --no-pager diff --name-only "$old" HEAD -- $IMAGE_PATHS 2>/dev/null || true)" ]; then need_build=1; fi
  if [ "$need_build" = 1 ]; then touch "$BUILD_MARK"; fi
  if [ ! -f config.yaml ]; then echo "Run $(launcher start) to set it up and start it."; return 0; fi
  if [ "$need_build" = 1 ]; then
    echo "    The server itself changed, so it is built again (10-30 minutes) and restarted."
    if yes_no "Do that now?" y; then start=1
    else echo "Run $(launcher start) when you are ready: it builds and restarts the server."
    fi
  elif server_running; then
    echo "    The running server does not need a restart for this update."
  elif yes_no "Start the server now?" y; then
    start=1
  else
    echo "Run $(launcher start) to start the server."
  fi
  # The new start script (git just replaced it) builds the image if needed and restarts the server.
  if [ -n "$start" ]; then exec bash ./start.sh; fi
}
