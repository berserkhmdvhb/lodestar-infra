#!/usr/bin/env bats
# A bare `make` lists the commands and runs no gate; every .PHONY target has a help row.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for t in tofu tflint checkov bats shellcheck gitleaks actionlint zizmor; do
    printf '#!/usr/bin/env bash\necho "%s called" >> "%s/called"\nexit 1\n' "$t" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/$t"
    chmod +x "$BATS_TEST_TMPDIR/bin/$t"
  done
}

# The Makefile prepends ./.tools/bin to PATH, so a stub there would be shadowed: none is needed
# because a bare make must not reach any gate at all.
@test "a bare make prints the header and runs no gate" {
  cd "$ROOT"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run make --no-print-directory
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Available Makefile commands:" ]
  [ ! -e "$BATS_TEST_TMPDIR/called" ]
}

@test "help rows match the .PHONY targets, except help itself" {
  cd "$ROOT"
  phony="$(sed -n 's/^\.PHONY: //p' Makefile | tr ' ' '\n' | grep -vx help | grep . | sort)"
  rows="$(make --no-print-directory help | tail -n +2 | awk 'NF {print $1}' | sort)"
  [ -n "$phony" ]
  [ "$phony" = "$(printf '%s\n' "$rows" | grep -vx help)" ]
  for r in $rows; do make -n "$r" >/dev/null; done
}
