#!/usr/bin/env bats
# A bare `make` lists the commands and runs no gate; every .PHONY target has a help row.
# No test runs a bare make or a gate: a default goal of check would run bats and recurse.

bats_require_minimum_version 1.5.0

setup() { cd "$BATS_TEST_DIRNAME/.." || return 1; }

@test "the default goal is the help recipe: a dry run shows no gate" {
  run --separate-stderr make -n --no-print-directory
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "printf 'Available Makefile commands:"* ]]
  # every line is a printf or one of its row arguments: nothing else (no gate) would run
  for l in "${lines[@]}"; do [[ "$l" == printf* || "$l" =~ ^[[:space:]]+[a-z-]+\ \".*\"[[:space:]]*\\?$ ]]; done
}

@test "make help prints the header first" {
  run --separate-stderr make --no-print-directory help
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Available Makefile commands:" ]
}

@test "help rows match the .PHONY targets, except help itself" {
  phony="$(sed -n 's/^\.PHONY: //p' Makefile | tr ' ' '\n' | grep -vx help | grep . | sort)"
  rows="$(make --no-print-directory help 2>/dev/null | tail -n +2 | awk 'NF {print $1}' | sort)"
  [ -n "$phony" ]
  [ "$phony" = "$(printf '%s\n' "$rows" | grep -vx help)" ]
  for r in $rows; do make -n --no-print-directory "$r" >/dev/null; done
}
