#!/usr/bin/env bash
# Install the pinned dev toolchain into ./.tools (never system-wide, never via a piped installer).
#
# Usage: scripts/tools.sh [--dry-run] install [name...]   install all pins, or just the named ones
#        scripts/tools.sh list                            show the pins for this platform
#
# Every download goes to a temp file, is checked against the sha256 in tools/pins.tsv, and only
# then extracted. A mismatch aborts before anything lands in .tools. Python tools install from
# hash-pinned requirements (tools/requirements/<name>.txt) into their own venv.
# Env overrides (used by the tests): PINS, TOOLS_DIR, TOOLS_PROTO (curl --proto, default =https).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS="${PINS:-$ROOT/tools/pins.tsv}"
REQS="${REQS:-$ROOT/tools/requirements}"
TOOLS_DIR="${TOOLS_DIR:-$ROOT/.tools}"
DRY_RUN=false # only --dry-run sets it
TMP="" PART=""

die() { echo "tools: $*" >&2; exit 1; }
cleanup() { rm -rf "${TMP:-}" "${PART:-}"; }
trap cleanup EXIT

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) PLATFORM=linux-amd64 ;;
  Darwin-arm64) PLATFORM=darwin-arm64 ;;
  *) die "unsupported platform $(uname -s)-$(uname -m)" ;;
esac

# run: print the argv and execute nothing under --dry-run.
run() {
  if [[ "$DRY_RUN" == "true" ]]; then echo "  -> $*"; else "$@"; fi
}

# Executable path(s) inside the unpacked artifact: "<relpath>:<link name>" (VER is the pinned version).
exes_for() {
  case "$1" in
    bats) echo "bats-core-$VER/bin/bats:bats" ;;
    shellcheck) echo "shellcheck-v$VER/shellcheck:shellcheck" ;;
    tflint-ruleset-google) echo "" ;;
    *) echo "$1:$1" ;;
  esac
}

# Entry points a Python tool's venv exposes in .tools/bin.
uv_exes_for() {
  case "$1" in
    *) echo "$1" ;;
  esac
}

verify() { # file sha256
  local got
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  [[ "$got" == "$2" ]] || die "checksum mismatch for $NAME $VER: expected $2, got $got; refusing to install"
}

# Interpreter for scripts/safe_extract.py: a system python3 >= 3.12, else the uv-managed one.
safe_python() {
  if python3 -c 'import sys; sys.exit(sys.version_info < (3, 12))' 2>/dev/null; then
    command -v python3
  else
    uv python find --managed-python "$(pin_version python)" 2>/dev/null \
      || die "$NAME: needs python >= 3.12 (system python3 too old; run 'scripts/tools.sh install python')"
  fi
}

# Extract with tarfile's "data" filter (refuses escaping names, links, devices; strips setuid).
safe_extract() { # archive dest
  local py
  py="$(safe_python)"
  "$py" -I "$ROOT/scripts/safe_extract.py" "$1" "$2" || die "$NAME: unsafe archive; refusing to install"
}

link_exes() { # dir of the unpacked artifact
  local pair rel name
  for pair in $(exes_for "$NAME"); do
    rel="${pair%%:*}"; name="${pair##*:}"
    [[ "$DRY_RUN" == "true" || -f "$1/$rel" ]] || die "$NAME: '$rel' not found in the artifact"
    run chmod +x "$1/$rel"
    run ln -sfn "$1/$rel" "$TOOLS_DIR/bin/$name"
  done
}

pin_version() { # name -> version of that pin (platform "any")
  awk -F'\t' -v n="$1" '!/^#/ && $1==n && $3=="any" {print $2; exit}' "$PINS"
}

install_uv() { # pkg
  local pkg="$1" req venv py exe pybin
  req="$REQS/$NAME.txt"
  [[ -f "$req" ]] || die "$NAME: missing hash-pinned requirements $req; refusing to install"
  grep -qiE "^${pkg//./\\.}==${VER//./\\.}([[:space:]\\]|\$)" "$req" || die "$NAME: $req does not pin $pkg==$VER; refusing to install"
  grep -q -- '--hash=sha256:' "$req" || die "$NAME: $req has no hashes; refusing to install"
  py="$(pin_version python)"
  venv="$TOOLS_DIR/uv-tools/$NAME"
  echo "==> $NAME $VER (uv, --require-hashes, python ${py:-default})"
  # The uv-managed interpreter by path, never a system python that happens to match 3.13.
  if [[ "$DRY_RUN" == "true" ]]; then
    pybin="<uv-managed python ${py:-3.13}>"
  else
    pybin="$(uv python find --managed-python "${py:-3.13}" 2>/dev/null || true)"
    if [[ -z "$pybin" ]]; then
      UV_PYTHON_BIN_DIR="$TOOLS_DIR/bin" uv python install "${py:-3.13}"
      pybin="$(uv python find --managed-python "${py:-3.13}")" || die "$NAME: no uv-managed python ${py:-3.13}"
    fi
  fi
  run rm -rf "$venv"
  run uv venv --quiet --python "$pybin" "$venv"
  run uv pip install --quiet --python "$venv/bin/python" --require-hashes --no-deps -r "$req"
  run mkdir -p "$TOOLS_DIR/bin"
  for exe in $(uv_exes_for "$NAME"); do
    run ln -sfn "$venv/bin/$exe" "$TOOLS_DIR/bin/$exe"
  done
}

install_pin() { # uses NAME VER URL SHA
  local dest file plug
  case "$URL" in
    uv:python)
      run env UV_PYTHON_BIN_DIR="$TOOLS_DIR/bin" uv python install "$VER"; return ;;
    uv:*) install_uv "${URL#uv:}"; return ;;
  esac
  dest="$TOOLS_DIR/opt/$NAME-$VER"
  if [[ -d "$dest" && "$DRY_RUN" != "true" ]]; then
    echo "$NAME $VER already installed"
  else
    echo "==> $NAME $VER ($URL)"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  -> download, verify sha256 $SHA, extract to $dest"
    else
      TMP="$(mktemp -d)"
      file="$TMP/${URL##*/}"
      curl -fsSL --proto "${TOOLS_PROTO:-=https}" --proto-redir =https -o "$file" "$URL"
      verify "$file" "$SHA"
      PART="$dest.part"
      rm -rf "$PART"
      mkdir -p "$PART"
      if [[ "$URL" == *.tar.* || "$URL" == *.tgz || "$URL" == *.zip ]]; then
        safe_extract "$file" "$PART"
      else
        cp "$file" "$PART/$NAME"
      fi
      mv "$PART" "$dest"
      PART=""
      rm -rf "$TMP"
      TMP=""
    fi
  fi
  if [[ "$NAME" == tflint-ruleset-google ]]; then
    # tflint's plugin layout: <plugin dir>/<source>/<version>/<binary>; Makefile sets TFLINT_PLUGIN_DIR.
    plug="$TOOLS_DIR/tflint-plugins/github.com/terraform-linters/$NAME/$VER"
    run mkdir -p "$plug"
    [[ "$DRY_RUN" == "true" || -f "$dest/$NAME" ]] || die "$NAME: '$NAME' not found in the artifact"
    run chmod +x "$dest/$NAME"
    run ln -sfn "$dest/$NAME" "$plug/$NAME"
  else
    run mkdir -p "$TOOLS_DIR/bin"
    link_exes "$dest"
  fi
}

# split_row LINE: set NAME VER PLAT URL SHA from exactly five tab-separated, non-empty fields.
split_row() {
  local line="$1" rest tabs
  tabs="${line//[^$'\t']/}"
  [[ ${#tabs} -eq 4 ]] || die "malformed pin (need exactly 5 tab-separated fields): $line"
  NAME="${line%%$'\t'*}"; rest="${line#*$'\t'}"
  VER="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  PLAT="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  URL="${rest%%$'\t'*}"; SHA="${rest#*$'\t'}"
  [[ -n "$NAME" && -n "$VER" && -n "$PLAT" && -n "$URL" && -n "$SHA" ]] || die "malformed pin (empty field): $line"
}

cmd_install() {
  local wanted=" $* " found=" " line n NAME VER PLAT URL SHA
  [[ -r "$PINS" ]] || die "cannot read $PINS"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    split_row "$line"
    [[ "$PLAT" == any || "$PLAT" == "$PLATFORM" ]] || continue
    [[ $# -eq 0 || "$wanted" == *" $NAME "* ]] || continue
    found+="$NAME "
    [[ "$URL" == uv:* || "$SHA" =~ ^[0-9a-f]{64}$ ]] || die "$NAME: pin has no sha256"
    install_pin
  done < "$PINS"
  for n in "$@"; do [[ "$found" == *" $n "* ]] || die "no pin named '$n' for $PLATFORM"; done
  if [[ "$DRY_RUN" == "true" ]]; then echo "dry-run: nothing was installed"; else echo "done: tools in $TOOLS_DIR/bin"; fi
}

cmd_list() {
  awk -F'\t' -v p="$PLATFORM" '!/^#/ && NF && ($3=="any" || $3==p) {print $1, $2}' "$PINS"
}

args=()
for a in "$@"; do
  if [[ "$a" == --dry-run ]]; then DRY_RUN=true; else args+=("$a"); fi
done
set -- "${args[@]:-}"
case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  list) cmd_list ;;
  *) die "usage: tools.sh [--dry-run] install [name...] | list" ;;
esac
