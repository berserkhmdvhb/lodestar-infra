#!/usr/bin/env bats
# Installer tests for scripts/tools.sh. Offline: pins point at local file:// artifacts
# (TOOLS_PROTO=file lets curl read them); nothing here touches the network.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="${TOOLS_SH:-$ROOT/scripts/tools.sh}"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/scratch"
  export TMPDIR="$D/scratch" TOOLS_DIR="$D/.tools" PINS="$D/pins.tsv" TOOLS_PROTO="=file"
  printf '#!/bin/sh\necho fake\n' > "$D/kind-linux-amd64"
}

pin() { printf 'kind\t9.9.9\tlinux-amd64\tfile://%s\t%s\n' "$D/kind-linux-amd64" "$1" > "$PINS"; }

@test "checksum mismatch is refused and nothing is installed" {
  pin "$(printf '0%.0s' {1..64})"
  run bash "$SCRIPT" install kind
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$TOOLS_DIR/bin" ]
  [ ! -e "$TOOLS_DIR/opt" ]
  [ -z "$(ls -A "$D/scratch")" ]
}

@test "matching checksum installs, second run skips" {
  pin "$(sha256sum "$D/kind-linux-amd64" | cut -d' ' -f1)"
  run bash "$SCRIPT" install kind
  [ "$status" -eq 0 ]
  [ -L "$TOOLS_DIR/bin/kind" ]
  TOOLS_PROTO="=https" run bash "$SCRIPT" install kind
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
}

@test "dry run installs nothing and never calls curl, uv, tar or wget" {
  pin "$(printf '0%.0s' {1..64})"
  mkdir "$D/stubs"
  for t in curl uv tar wget; do
    printf '#!/bin/sh\necho %s >> "%s"\nexit 1\n' "$t" "$D/calls.log" > "$D/stubs/$t"
    chmod +x "$D/stubs/$t"
  done
  PATH="$D/stubs:$PATH" run bash "$SCRIPT" --dry-run install kind
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing was installed"* ]]
  [ ! -e "$TOOLS_DIR" ]
  [ ! -e "$D/calls.log" ]
}

@test "a DRY_RUN environment variable does not enable dry run" {
  pin "$(printf '0%.0s' {1..64})"
  DRY_RUN=true run bash "$SCRIPT" install kind
  [ "$status" -ne 0 ]
  [ ! -e "$TOOLS_DIR" ]
}

@test "a pins file with a malformed line is rejected" {
  printf 'kind\t1\tlinux-amd64\turl\n' > "$PINS"
  run bash "$SCRIPT" install
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed pin"* ]]
  printf 'kind\t\tlinux-amd64\turl\t%s\n' "$(printf '0%.0s' {1..64})" > "$PINS"
  run bash "$SCRIPT" install
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed pin"* ]]
}

@test "a pin without a sha256 is rejected" {
  pin "-"
  run bash "$SCRIPT" install kind
  [ "$status" -ne 0 ]
  [[ "$output" == *"no sha256"* ]]
}

@test "an archive with an escaping member is refused" {
  python3 -I - "$D/kind-linux-amd64.tar.gz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tf:
    i = tarfile.TarInfo("../escape")
    i.size = 1
    tf.addfile(i, io.BytesIO(b"x"))
PY
  sha="$(sha256sum "$D/kind-linux-amd64.tar.gz" | cut -d' ' -f1)"
  printf 'kind\t9.9.9\tlinux-amd64\tfile://%s\t%s\n' "$D/kind-linux-amd64.tar.gz" "$sha" > "$PINS"
  run bash "$SCRIPT" install kind
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe archive"* ]]
  [ ! -e "$TOOLS_DIR/bin" ]
  [ ! -e "$D/escape" ]
}

@test "a zip with a symlink member is refused" {
  python3 -I - "$D/kind-linux-amd64.zip" <<'PY'
import stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as zf:
    i = zipfile.ZipInfo("kind")
    i.external_attr = (stat.S_IFLNK | 0o777) << 16
    zf.writestr(i, "/etc/passwd")
PY
  sha="$(sha256sum "$D/kind-linux-amd64.zip" | cut -d' ' -f1)"
  printf 'kind\t9.9.9\tlinux-amd64\tfile://%s\t%s\n' "$D/kind-linux-amd64.zip" "$sha" > "$PINS"
  run bash "$SCRIPT" install kind
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe archive"* ]]
  [ ! -e "$TOOLS_DIR/bin" ]
}

@test "nothing is piped into a shell, and downloads allow only https redirects" {
  run grep -nE '(curl|wget)[^#]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh\b' "$ROOT/scripts/tools.sh" "$ROOT/Makefile"
  [ "$status" -ne 0 ]
  run grep -nE '\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]]|$)|bash <\(|sh -c "\$\(curl' "$ROOT/scripts/tools.sh" "$ROOT/Makefile"
  [ "$status" -ne 0 ]
  grep -q -- '--proto-redir =https' "$ROOT/scripts/tools.sh"
  grep -q 'trap cleanup EXIT' "$ROOT/scripts/tools.sh"
}

@test "every shipped pin has a 64-hex sha256 or a hashed requirements file" {
  while IFS=$'\t' read -r name ver plat url sha; do
    case "$name" in '#'*|'') continue ;; esac
    if [[ "$url" == uv:python ]]; then continue; fi
    if [[ "$url" == uv:* ]]; then
      grep -q -- '--hash=sha256:' "$ROOT/tools/requirements/$name.txt"
      grep -qiE "^${url#uv:}==${ver//./\\.}( |\\\\|$)" "$ROOT/tools/requirements/$name.txt"
    else
      [[ "$sha" =~ ^[0-9a-f]{64}$ ]]
      [[ "$url" == https://* ]]
    fi
  done < "$ROOT/tools/pins.tsv"
}

# scripts/safe_extract.py zip path, driven directly. mkzip <name> <mode-or--> <zip>
mkzip() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import sys, zipfile
name, mode, out = sys.argv[1:]
with zipfile.ZipFile(out, "w") as zf:
    i = zipfile.ZipInfo(name)
    if mode != "-":
        i.external_attr = int(mode, 8) << 16
    zf.writestr(i, "x")
PY
}

@test "zip: a .. member is refused and writes nothing outside dest" {
  mkzip "../evil" 100644 "$D/a.zip"
  mkdir "$D/dest"
  run python3 -I "$ROOT/scripts/safe_extract.py" "$D/a.zip" "$D/dest"
  [ "$status" -ne 0 ]
  [ ! -e "$D/evil" ]
  [ -z "$(ls -A "$D/dest")" ]
}

@test "zip: an absolute-path member is refused and writes nothing there" {
  mkzip "$D/abs/evil" 100644 "$D/a.zip"
  mkdir "$D/dest"
  run python3 -I "$ROOT/scripts/safe_extract.py" "$D/a.zip" "$D/dest"
  [ "$status" -ne 0 ]
  [ ! -e "$D/abs" ]
  [ -z "$(ls -A "$D/dest")" ]
}

@test "zip: FIFO and character-device members are refused" {
  mkdir "$D/dest"
  for mode in 010644 020644; do
    mkzip "special" "$mode" "$D/a.zip"
    run python3 -I "$ROOT/scripts/safe_extract.py" "$D/a.zip" "$D/dest"
    [ "$status" -ne 0 ]
    [ -z "$(ls -A "$D/dest")" ]
  done
}

@test "zip: a good zip extracts and no setuid or setgid bit survives" {
  python3 -I - "$D/good.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as zf:
    d = zipfile.ZipInfo("sub/")
    d.external_attr = (0o40755 << 16) | 0x10
    zf.writestr(d, "")
    f = zipfile.ZipInfo("sub/tool")
    f.external_attr = 0o104755 << 16
    zf.writestr(f, "payload")
PY
  mkdir "$D/dest"
  run python3 -I "$ROOT/scripts/safe_extract.py" "$D/good.zip" "$D/dest"
  [ "$status" -eq 0 ]
  [ "$(cat "$D/dest/sub/tool")" = payload ]
  [ ! -u "$D/dest/sub/tool" ]
  [ ! -g "$D/dest/sub/tool" ]
}
