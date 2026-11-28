#!/usr/bin/env bats
# Static checks of docs/production-runbook.md: links resolve, code blocks parse in bash and zsh, and the
# style rules hold (no comments, braced variables, printf, an Expect line after every block, no real values).

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DOC="$ROOT/docs/production-runbook.md"
}

# usage: blocks <dir>: writes every ```bash block of the runbook to <dir>/NNN.sh
blocks() {
  mkdir -p "$1"
  awk -v d="$1" '
    /^```bash$/ { n++; f = sprintf("%s/%03d.sh", d, n); on = 1; next }
    /^```$/ && on { on = 0; close(f); next }
    on { print > f }
  ' "$DOC"
}

# GitHub heading slug
slug() { tr 'A-Z' 'a-z' | sed -E 's/[`]//g; s/[^a-z0-9 _-]//g; s/ /-/g'; }

@test "the runbook exists and has a block per step" {
  [ -f "$DOC" ]
  blocks "$BATS_TEST_TMPDIR/b"
  [ "$(ls "$BATS_TEST_TMPDIR/b" | wc -l)" -gt 30 ]
}

@test "every relative link resolves, anchors included" {
  while IFS= read -r link; do
    path="${link%%#*}"
    anchor=""
    [[ "$link" == *"#"* ]] && anchor="${link#*#}"
    target="$ROOT/docs/$path"
    [ -z "$path" ] && target="$DOC"
    [ -e "$target" ] || { echo "broken link: $link"; return 1; }
    if [ -n "$anchor" ] && [[ "$target" == *.md ]]; then
      grep -E '^#{1,6} ' "$target" | sed -E 's/^#+ +//' | while IFS= read -r h; do printf '%s\n' "$h" | slug; done | grep -qxF -- "$anchor" \
        || { echo "missing anchor: $link"; return 1; }
    fi
  done < <(grep -oE '\]\([^)]+\)' "$DOC" | sed -E 's/^\]\(//; s/\)$//' | grep -vE '^(https?:|mailto:)')
}

@test "the operations runbook links to the production runbook" {
  grep -qF '](../production-runbook.md)' "$ROOT/docs/operations/README.md"
}

@test "every code block passes bash -n" {
  blocks "$BATS_TEST_TMPDIR/b"
  for f in "$BATS_TEST_TMPDIR"/b/*.sh; do bash -n "$f" || { echo "bash -n failed: $f"; return 1; }; done
}

@test "every code block passes zsh -n" {
  command -v zsh >/dev/null || skip "zsh not installed"
  blocks "$BATS_TEST_TMPDIR/b"
  for f in "$BATS_TEST_TMPDIR"/b/*.sh; do zsh -n "$f" || { echo "zsh -n failed: $f"; return 1; }; done
}

@test "no comments, no echo, braced variables outside single quotes" {
  blocks "$BATS_TEST_TMPDIR/b"
  for f in "$BATS_TEST_TMPDIR"/b/*.sh; do
    if grep -nE '^[[:space:]]*#' "$f"; then echo "comment in $f"; return 1; fi
    if grep -nE '(^|[|;&(]|[[:space:]])echo[[:space:]]' "$f"; then echo "echo in $f"; return 1; fi
    if sed -E "s/'[^']*'//g" "$f" | grep -nE '\$[A-Za-z_]'; then echo "unbraced variable in $f"; return 1; fi
  done
}

@test "every code block is followed by an Expect line" {
  run awk '
    /^```bash$/ { on = 1; next }
    /^```$/ && on { on = 0; wait = 1; blk = NR; next }
    wait && NF { if ($0 !~ /^Expect/) { print "block ending at line " blk " is followed by: " $0; bad = 1 } wait = 0 }
    END { exit bad }
  ' "$DOC"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "no real identifiers: no long digit runs, no e-mail, no key material" {
  run ! grep -nE '[0-9]{9,}|[A-Za-z0-9._-]+@[A-Za-z0-9-]+\.(com|org|net|io)|BEGIN .*PRIVATE|ghp_|gho_' "$DOC"
}

@test "the add-count arithmetic matches the L4.3 inventory of 51 for 2 services and 3 keys" {
  [ "$((9 + 4 + 2 + 2 + 3 + 1 + 12 + 2 + 1))" -eq 36 ]
  [ "$((36 + 6 * 2 + 3))" -eq 51 ]
  [ "$((36 + 10 * 2 + 3))" -eq 59 ]
  [ "$((36 + 10 * 3 + 4))" -eq 70 ]
  grep -qF 'N = 36 + 10 * S + K' "$DOC"
  grep -qF 'K = 4, so N = 36 + 30 + 4 = 70' "$DOC"
}

@test "the add-count awk groups a sample plan by module" {
  out="$(printf '%s\n' \
    '  # module.project.google_project_service.apis["a.googleapis.com"] will be created' \
    '  # module.github_wif["web"].google_iam_workload_identity_pool.this will be created' \
    '  # module.github_wif["web"].google_iam_workload_identity_pool_provider.this will be created' \
    '  # module.gke.google_container_cluster.this will be updated in-place' \
    | awk '/ will be created$/ {split($2, a, "."); print a[1] "." a[2]}' | sort | uniq -c | tr -s ' ')"
  [ "$out" = $' 2 module.github_wif["web"]\n 1 module.project' ]
}

@test "every directory with a lock file is listed in dependabot.yml" {
  cd "$ROOT"
  missing=""
  while IFS= read -r d; do
    d="/${d%/.terraform.lock.hcl}"
    case "$d" in
      /modules/*) grep -qE '^      - /modules/\*$' .github/dependabot.yml || missing="$missing $d" ;;
      *) grep -qE "^      - ${d}\$" .github/dependabot.yml || missing="$missing $d" ;;
    esac
  done < <(find bootstrap envs modules -name .terraform.lock.hcl -not -path '*/.terraform/*')
  [ -z "$missing" ] || { echo "not in dependabot.yml:$missing"; return 1; }
}
