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

# The only intended edits to code blocks (zsh does not treat # as a comment by default, and echo is against the rules):
# the three comment lines of the 9.1 vars-file block moved to prose before it, and `echo "exit=$?"` became printf.
# Applied to the old blocks before comparing, so any OTHER block change still fails.
oldblocks() {
  blocks "$OLD" | sed \
    -e 's/# Repository variables\f//' \
    -e 's/# Environment variables (the same provider, a different deployer each)\f//' \
    -e 's/# Script input, never sent as a variable: the production reviewer (you)\f//' \
    -e 's/echo "exit=\$?"/printf '"'"'exit=%s\\n'"'"' "$?"/g'
}

@test "every fenced block of the old file (with the 6 documented edits) is still in the new set, verbatim, once" {
  oldblocks | LC_ALL=C sort > "$BATS_TEST_TMPDIR/old"
  blocks "${NEW[@]}" | LC_ALL=C sort > "$BATS_TEST_TMPDIR/new"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/old")" -gt 100 ]
  run env LC_ALL=C comm -23 "$BATS_TEST_TMPDIR/old" "$BATS_TEST_TMPDIR/new"
  echo "$output" | tr '\f' '~' | head -20
  [ -z "$output" ]
  run env LC_ALL=C comm -12 "$BATS_TEST_TMPDIR/old" <(uniq -d "$BATS_TEST_TMPDIR/new")
  echo "$output" | tr '\f' '~' | head -20
  [ -z "$output" ]
}

@test "every prose line of the old file is in the new set, except the listed intended edits" {
  # Allowlist of old lines that were intentionally rewritten: the intro and the hardening and CI-identity pointers
  # (relative links gained ../), the production pointer (its "below" is gone and its link gained ../), and the
  # numbered Contents list (now the section map table).
  # Also two lines that name the echo line of the 5.4 probe, which became a printf line (the second is a table row;
  # the table test has its own substitution for it).
  allow=(
    "| \`wget: bad port '8080;'\` in the NetworkPolicy probe | the \`;\` of \`...:8080; echo \"exit=\$?\"\` reached \`wget\` as part of the URL | put \`echo \"exit=\$?\"\` on its own line (5.4) |"
    'backslash from another paste route gives the same result. Keep `echo "exit=$?"` on its own line, as above. The result of probe B is only valid if the failure'
    '[`import-runbook.md`](import-runbook.md), [`hardening-runbook.md`](hardening-runbook.md) and'
    '[`production-runbook.md`](production-runbook.md) (the separate production project and cluster). It collects the'
    'The production project and its regional cluster are built by [`production-runbook.md`](production-runbook.md),'
    "which reuses the commands of sections 5, 7, 8 and 12 below with production's names."
    'API. The detail and the acceptance rules are in [`hardening-runbook.md`](hardening-runbook.md); this is the'
    'the identity and the rollback are in [`ci-identity-runbook.md`](ci-identity-runbook.md); this is the command'
  )
  outside "$OLD" | grep -v '^[[:space:]]*$' > "$BATS_TEST_TMPDIR/oldp"
  outside "${NEW[@]}" > "$BATS_TEST_TMPDIR/newp"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/oldp")" -gt 800 ]
  bad=0
  while IFS= read -r line; do
    grep -qxF -- "$line" "$BATS_TEST_TMPDIR/newp" && continue
    [[ "$line" =~ ^[0-9]+\.\ \[.*\]\(#[a-z0-9-]+\)$ ]] && continue
    skip=0
    for a in "${allow[@]}"; do [ "$line" = "$a" ] && skip=1; done
    [ "$skip" = 1 ] && continue
    echo "dropped or edited: $line"
    bad=1
  done < "$BATS_TEST_TMPDIR/oldp"
  [ "$bad" -eq 0 ]
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
  # One intended edit: the fix column of the bad-port row names the printf line that replaced the echo line.
  outside "$OLD" | grep -E '^\|' | sed -e 's/put `echo "exit=\$?"` on its own line (5.4)/put `printf '"'"'exit=%s\\n'"'"' "$?"` on its own line (5.4)/' | LC_ALL=C sort > "$BATS_TEST_TMPDIR/old"
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

@test "no code block has a comment line (a #! line aside) or an echo" {
  blocks "${NEW[@]}" | tr '\f' '\n' > "$BATS_TEST_TMPDIR/all"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/all")" -gt 500 ]
  run grep -nE '^[[:space:]]*#([^!]|$)|(^|[|;&(]|[[:space:]])echo[[:space:]]' "$BATS_TEST_TMPDIR/all"
  echo "$output"
  [ "$status" -eq 1 ]
}
