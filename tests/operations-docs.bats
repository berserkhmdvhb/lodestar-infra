#!/usr/bin/env bats
# Proves that the split of the old operations runbook into docs/operations/ lost nothing: every fenced block, Expect
# line, table row and heading of the pre-split file (tests/fixtures/operations-runbook.pre-split.md, a committed
# copy so a shallow clone needs no git history) is in the new set. Also: links resolve, blocks parse, no new style
# violations.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  OLD="$BATS_TEST_DIRNAME/fixtures/operations-runbook.pre-split.md"
  NEWDIR="$ROOT/docs/operations"
  NEW=("$NEWDIR"/*.md)
}

# usage: blocks <file>...: one line per fenced block, newlines replaced by a form feed
blocks() {
  awk '
    /^```/ { if (on) { print buf; on = 0 } else { on = 1; buf = "" } next }
    on { buf = buf $0 "\f" }
  ' "$@"
}

# usage: outside <file>...: the lines that are not inside a fenced block
outside() {
  awk 'FNR == 1 { on = 0 } /^```/ { on = !on; next } !on' "$@"
}

# usage: bashfiles <dir>: writes every ```bash block of the new set to <dir>/<file>-NNN.sh
bashfiles() {
  mkdir -p "$1"
  for doc in "${NEW[@]}"; do
    awk -v d="$1" -v p="$(basename "$doc" .md)" '
      /^```bash$/ { n++; f = sprintf("%s/%s-%03d.sh", d, p, n); on = 1; next }
      /^```/ && on { on = 0; close(f); next }
      on { print > f }
    ' "$doc"
  done
}

# GitHub heading slug
slug() { tr 'A-Z' 'a-z' | sed -E 's/[`]//g; s/[^a-z0-9 _-]//g; s/ /-/g'; }

# usage: headings <file>...: heading text without its number
headings() { outside "$@" | grep -E '^#{1,6} ' | sed -E 's/^#+ +//; s/^[0-9]+(\.[0-9]+)*\.? +//' | LC_ALL=C sort -u; }

@test "the new set exists, the old file is a short stub, cloudflare.md is not written yet" {
  for f in README workstation gcp-foundation gke github-identity secrets github-settings opentofu troubleshooting glossary; do
    [ -f "$NEWDIR/$f.md" ] || { echo "missing: $f.md"; return 1; }
  done
  [ ! -e "$NEWDIR/cloudflare.md" ]
  [ "$(wc -l < "$ROOT/docs/operations-runbook.md")" -lt 20 ]
  grep -qF '](operations/README.md)' "$ROOT/docs/operations-runbook.md"
}

@test "every fenced block of the old file is in the new set, verbatim, once" {
  blocks "$OLD" | LC_ALL=C sort > "$BATS_TEST_TMPDIR/old"
  blocks "${NEW[@]}" | LC_ALL=C sort > "$BATS_TEST_TMPDIR/new"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/old")" -gt 100 ]
  run diff "$BATS_TEST_TMPDIR/old" "$BATS_TEST_TMPDIR/new"
  echo "$output" | tr '\f' '~' | head -20
  [ "$status" -eq 0 ]
}

@test "every Expect line of the old file is in the new set" {
  outside "$OLD" | grep -E '^Expect' | LC_ALL=C sort > "$BATS_TEST_TMPDIR/old"
  outside "${NEW[@]}" | grep -E '^Expect' | LC_ALL=C sort > "$BATS_TEST_TMPDIR/new"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/old")" -gt 60 ]
  run env LC_ALL=C comm -23 "$BATS_TEST_TMPDIR/old" "$BATS_TEST_TMPDIR/new"
  echo "$output"
  [ -z "$output" ]
}

@test "every table row of the old file is in the new set" {
  outside "$OLD" | grep -E '^\|' | LC_ALL=C sort > "$BATS_TEST_TMPDIR/old"
  outside "${NEW[@]}" | grep -E '^\|' | LC_ALL=C sort > "$BATS_TEST_TMPDIR/new"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/old")" -gt 50 ]
  run env LC_ALL=C comm -23 "$BATS_TEST_TMPDIR/old" "$BATS_TEST_TMPDIR/new"
  echo "$output"
  [ -z "$output" ]
}

@test "every heading of the old file is a heading in the new set" {
  headings "$OLD" > "$BATS_TEST_TMPDIR/old"
  headings "${NEW[@]}" > "$BATS_TEST_TMPDIR/new"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/old")" -gt 60 ]
  run env LC_ALL=C comm -23 "$BATS_TEST_TMPDIR/old" "$BATS_TEST_TMPDIR/new"
  echo "$output"
  [ -z "$output" ]
}

@test "every relative link resolves, anchors included" {
  for doc in "${NEW[@]}" "$ROOT/docs/production-runbook.md" "$ROOT/README.md" "$ROOT/docs/operations-runbook.md"; do
    while IFS= read -r link; do
      path="${link%%#*}"
      anchor=""
      [[ "$link" == *"#"* ]] && anchor="${link#*#}"
      target="$(dirname "$doc")/$path"
      [ -z "$path" ] && target="$doc"
      [ -e "$target" ] || { echo "broken link in $doc: $link"; return 1; }
      if [ -n "$anchor" ] && [[ "$target" == *.md ]]; then
        outside "$target" | grep -E '^#{1,6} ' | sed -E 's/^#+ +//' | while IFS= read -r h; do printf '%s\n' "$h" | slug; done | grep -qxF -- "$anchor" \
          || { echo "missing anchor in $doc: $link"; return 1; }
      fi
    done < <(outside "$doc" | grep -oE '\]\([^)]+\)' | sed -E 's/^\]\(//; s/\)$//' | grep -vE '^(https?:|mailto:)')
  done
}

@test "every bash block passes bash -n" {
  bashfiles "$BATS_TEST_TMPDIR/b"
  [ "$(ls "$BATS_TEST_TMPDIR/b" | wc -l)" -gt 100 ]
  for f in "$BATS_TEST_TMPDIR"/b/*.sh; do bash -n "$f" || { echo "bash -n failed: $f"; return 1; }; done
}

@test "every bash block passes zsh -n" {
  command -v zsh >/dev/null || skip "zsh not installed"
  bashfiles "$BATS_TEST_TMPDIR/b"
  for f in "$BATS_TEST_TMPDIR"/b/*.sh; do zsh -n "$f" || { echo "zsh -n failed: $f"; return 1; }; done
}

@test "the split adds no comment and no echo to the code blocks (the old file's own are kept, not fixed)" {
  oc="$(blocks "$OLD" | tr '\f' '\n' | grep -cE '^[[:space:]]*#' || true)"
  nc="$(blocks "${NEW[@]}" | tr '\f' '\n' | grep -cE '^[[:space:]]*#' || true)"
  oe="$(blocks "$OLD" | tr '\f' '\n' | grep -cE '(^|[|;&(]|[[:space:]])echo[[:space:]]' || true)"
  ne="$(blocks "${NEW[@]}" | tr '\f' '\n' | grep -cE '(^|[|;&(]|[[:space:]])echo[[:space:]]' || true)"
  echo "comments old=$oc new=$nc; echo old=$oe new=$ne"
  [ "$oc" -eq "$nc" ]
  [ "$oe" -eq "$ne" ]
}
