# Optional extensions: folders in extensions/ with an extension.yaml (title, description, needs, download_gb), a
# docker-compose.yml (the extension's service, plus a "download" service under the download profile), and setup.sh,
# which defines ext_<name>_setup: the extension's own questions; it writes extensions/<name>/.env and returns false
# when the extension cannot run here. Installed extensions are listed under extensions.enabled in config.yaml; the
# image server then offers their tools on its own MCP address. Sourced by lib.sh (bash 3.2 compatible).

ext_available() {
  local f
  for f in extensions/*/extension.yaml; do
    if [ -f "$f" ]; then basename "$(dirname "$f")"; fi
  done
}
# ext_field NAME KEY: a one-line value from extensions/NAME/extension.yaml.
ext_field() {
  sed -nE "s/^$2:[[:space:]]*(.*)$/\1/p" "extensions/$1/extension.yaml" | head -n1 |
    sed -E 's/[[:space:]]+#.*$//; s/^"(.*)"$/\1/' | tr -d '\r'
}
# ext_description NAME: the folded description block.
ext_description() {
  awk '/^description:/ { on = 1; next } on && /^[^ \t]/ { exit } on { sub(/^[ \t]+/, ""); sub(/\r$/, ""); printf "%s ", $0 }' \
    "extensions/$1/extension.yaml"
}
# ext_enabled: the names under extensions.enabled in config.yaml.
ext_enabled() {
  [ -f config.yaml ] || return 0
  awk '/^extensions:/ { on = 1; next } on && /^[^ \t#]/ { exit }
       on && /^[ \t]+enabled[ \t]*:/ { s = $0; sub(/^[^:]*:[ \t]*/, "", s); sub(/#.*/, "", s); gsub(/[][ \t\r"'"'"']/, "", s)
                                       gsub(/,/, " ", s); print s }' config.yaml
}
ext_is_enabled() { case " $(ext_enabled) " in *" $1 "*) return 0 ;; esac; return 1; }
# ext_set_enabled "NAME NAME...": write extensions.enabled.
ext_set_enabled() {
  local list
  list=$(printf '%s\n' $1 | awk 'NF { printf "%s%s", (n++ ? ", " : ""), $0 }')
  set_yaml config.yaml enabled "[$list]" extensions
}
ext_compose() { local n=$1; shift; docker compose -f "extensions/$n/docker-compose.yml" "$@"; }

# ext_setup: after the image settings are saved, ask about each extension.
ext_setup() {
  local name title def keep=
  for name in $(ext_available); do
    [ -f "extensions/$name/setup.sh" ] || continue
    title=$(ext_field "$name" title)
    echo
    echo "Optional extension: $title"
    ext_description "$name" | fold -s -w 110 | sed 's/^/    /'
    echo
    if [ "$(ext_field "$name" needs)" = nvidia ] && [ "${GPU_COUNT:-0}" -eq 0 ]; then
      echo "    It needs an NVIDIA GPU. None was found, so it is not offered."
      if ext_is_enabled "$name"; then ext_remove "$name"; fi
      continue
    fi
    def=n
    if ext_is_enabled "$name"; then def=y; fi
    if yes_no "Install this extension?" "$def"; then
      # shellcheck disable=SC1090
      . "extensions/$name/setup.sh"
      if "ext_$(printf '%s' "$name" | tr '-' '_')_setup"; then
        keep="$keep $name"
      elif ext_is_enabled "$name"; then
        ext_remove "$name"
      fi
    elif ext_is_enabled "$name"; then
      ext_remove "$name"
    fi
  done
  ext_set_enabled "$keep"
}

# ext_remove NAME: stop it and take it out of config.yaml; its downloaded files are deleted only when asked.
ext_remove() {
  local gb
  echo "==> Removing the $1 extension."
  ext_compose "$1" down >/dev/null 2>&1 || true
  docker image rm "imagegen-$1:latest" >/dev/null 2>&1 || true  # its Docker image (several GB)
  ext_set_enabled "$(ext_enabled | tr ' ' '\n' | grep -vx "$1" | tr '\n' ' ')"
  if [ -d "extensions/$1/models" ]; then
    gb=$(ext_field "$1" download_gb)
    if yes_no "Also delete its downloaded files (about ${gb:-?} GB)?" n; then rm -rf "extensions/$1/models"; fi
  fi
}

# ext_start_all: build (once, or after an update), download (once) and start every installed extension.
ext_start_all() {
  local name state i
  for name in $(ext_enabled); do
    if [ ! -f "extensions/$name/docker-compose.yml" ]; then
      echo "Extension $name is listed in config.yaml, but extensions/$name is missing." >&2
      continue
    fi
    if [ ! -f "extensions/$name/.env" ]; then
      echo "Extension $name has no settings yet: run $(launcher setup)." >&2
      continue
    fi
    echo
    echo "==> Extension: $(ext_field "$name" title)"
    if [ -f "extensions/$name/.build-needed" ] || ! docker image inspect "imagegen-$name:latest" >/dev/null 2>&1; then
      echo "    Building its image (the first time takes several minutes)..."
      if ! ext_compose "$name" build; then echo "The $name extension could not be built." >&2; continue; fi
      rm -f "extensions/$name/.build-needed"
    fi
    if [ ! -f "extensions/$name/models/.ready" ]; then
      echo "    Downloading its models once (about $(ext_field "$name" download_gb) GB) and checking them..."
      mkdir -p "extensions/$name/models"
      if ! ext_compose "$name" --profile download run --rm download; then
        echo "The $name extension's download did not finish. Run $(launcher start) again to continue it." >&2
        continue
      fi
      touch "extensions/$name/models/.ready"
    fi
    if ! ext_compose "$name" up -d; then echo "The $name extension could not be started." >&2; continue; fi
    state=
    for i in $(seq 1 40); do
      state=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "imagegen-$name" 2>/dev/null | tr -d '\r')
      case "$state" in healthy|running) break ;; esac
      sleep 3
    done
    case "$state" in
      healthy|running) echo "    Ready. Its tools are offered on the server's MCP address within a few seconds." ;;
      *) echo "    It did not start ($state). See: docker logs imagegen-$name" >&2 ;;
    esac
  done
}

# ext_stop_all: stop every extension that has a container (installed or not).
ext_stop_all() {
  local name
  for name in $(ext_available); do
    if docker inspect "imagegen-$name" >/dev/null 2>&1; then ext_compose "$name" down >/dev/null 2>&1 || true; fi
  done
}

# ext_mark_changed OLD NEW: after an update, rebuild the extensions whose files changed between the two commits.
ext_mark_changed() {
  local name
  for name in $(ext_available); do
    if ! git diff --quiet "$1" "$2" -- "extensions/$name" 2>/dev/null; then touch "extensions/$name/.build-needed"; fi
  done
}
