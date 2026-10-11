# The video extension's setup questions, sourced by scripts/extensions.sh after the image settings are saved.
# Uses lib.sh's GPU list (GPU_ROWS, gpu_gb, ask, read_choice, set_yaml) and the image placement (PLACE_IMG, PLACE_TE,
# PLACE_DEC, DEVICE_REC). Writes extensions/kandinsky6/.env. Returns false when video cannot run here.
#
# Modes, measured at 864x480, 5 s with sound (see docs/kandinsky6.md):
#   own GPU:    20 GB+ resident (5090: 43-70 s) | 14-19 GB fast | 10-13 GB low-memory (3080 Ti 115-122 s, 3080 161-174 s)
#               | 8-9 GB stream
#   shared GPU: 24 GB+ fast, both run at once | 13-23 GB stream, both at once | 12 GB or less: stream, one job at a
#               time (3080 Ti 139-147 s), and the image model is limited to the card's memory minus 6 GB.

ext_kandinsky6_setup() {
  local idx= gb uuid shared=no mode cap= limit= mem=20g i def n choice note used rows name gpugb need
  if [ "${DEVICE_REC:-cpu}" = gpu ]; then
    used=" $(printf '%s ' $PLACE_IMG $PLACE_TE $PLACE_DEC) "
  else
    used=" "
  fi
  # Default: the largest GPU (8 GB or more) the image model does not use; otherwise the image model's GPU.
  def=$(printf '%s\n' "$GPU_ROWS" | sort -t'|' -k3,3nr -s | awk -F'|' -v u="$used" '$3 >= 8 && index(u, " " $1 " ") == 0 { print $1; exit }')
  if [ -z "$def" ]; then def=$(printf '%s\n' "$GPU_ROWS" | sort -t'|' -k3,3nr -s | head -n1 | cut -d'|' -f1); fi
  if [ "$GPU_COUNT" -gt 1 ]; then
    echo
    echo "Which GPU should the video use?"
    n=0
    rows=$(printf '%s\n' "$GPU_ROWS")
    while IFS='|' read -r i name gpugb; do
      n=$((n + 1))
      note=""
      case "$used" in *" $i "*) note=" (the image model uses it)" ;; esac
      echo "  $n) GPU $i: $name, $gpugb GB$note"
      if [ "$i" = "$def" ]; then choice=$n; fi
    done <<EOF
$rows
EOF
    read_choice "$n" "${choice:-1}"
    idx=$(printf '%s\n' "$GPU_ROWS" | sed -n "${CHOICE}p" | cut -d'|' -f1)
  else
    idx=$def
  fi
  gb=$(gpu_gb "$idx")
  if [ "${gb:-0}" -lt 8 ]; then
    echo "The video needs a GPU with 8 GB or more; GPU $idx has ${gb:-0} GB. The extension is not installed."
    return 1
  fi
  uuid=$(nvidia-smi --query-gpu=index,uuid --format=csv,noheader 2>/dev/null | tr -d '\r' |
    awk -F', *' -v i="$idx" '$1 == i { print $2; exit }')
  case "$used" in *" $idx "*) shared=yes ;; esac
  if [ "$shared" = yes ]; then
    if [ "$gb" -ge 24 ]; then
      mode=fast; limit=$((gb - 13))
    elif [ "$gb" -ge 13 ]; then
      mode=stream; limit=$((gb - 7))
    else
      mode=stream; limit=$((gb - 6)); [ "$limit" -lt 2 ] && limit=2
    fi
    if [ "${SPLIT:-0}" = 1 ]; then
      echo "Note: the image model is split across GPUs, so its memory limits are left as they are."
    else
      set_yaml config.yaml max_vram_gb "{$idx: $limit}" gpu || return 1
    fi
  else
    if [ "$gb" -ge 20 ]; then mode=resident; mem=12g
    elif [ "$gb" -ge 14 ]; then mode=fast
    elif [ "$gb" -ge 10 ]; then mode=low-memory; cap=$(awk -v g="$gb" 'BEGIN { printf "%.1f", g - (g >= 12 ? 2.5 : 1.5) }')
    else mode=stream
    fi
  fi
  {
    echo "# Written by the setup (run it again to change). See .env.example."
    echo "VIDEO_GPU=${uuid:-$idx}"
    echo "VIDEO_MODE=$mode"
    echo "VIDEO_CAP_GB=$cap"
    echo "VIDEO_MEM_LIMIT=$mem"
    echo "VIDEO_IDLE_UNLOAD_SECONDS=600"
    echo "SHARES_IMAGE_GPU=$shared"
    echo "GPU_GB=$gb"
  } > extensions/kandinsky6/.env
  echo
  echo "==> Video: GPU $idx ($gb GB), mode $mode."
  if [ "$shared" = yes ] && [ "$gb" -le 12 ]; then
    echo "    It shares this GPU with the image model: one job runs at a time (a video waits for an image and the"
    echo "    other way round), and the image model is limited to $limit GB. About 2.5 minutes per 5 s of video."
  elif [ "$shared" = yes ]; then
    echo "    It shares this GPU with the image model; both can run at once (image model limited to $limit GB)."
  fi
  # Measured peaks: the image server 6-15 GB, the video 7 GB (resident) or 13-16 GB (the other modes).
  need=31
  if [ "$mode" = resident ]; then need=22; fi
  if [ "${DOCKER_GB:-0}" -gt 0 ] && [ "$DOCKER_GB" -lt "$need" ]; then
    echo "    Warning: Docker can use $DOCKER_GB GB of memory. The image server and the video together need up to"
    echo "    about $need GB. See docs/kandinsky6.md."
  fi
  return 0
}
