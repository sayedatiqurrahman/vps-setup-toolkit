#!/usr/bin/env bash
# Run all syntax checks and non-destructive test suites.

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

fail=0
printf '== Bash syntax checks ==\n'
mapfile -d '' scripts < <(find . -type f -name '*.sh' -print0)
for script in "${scripts[@]}"; do
  if bash -n "$script"; then
    printf '  OK   %s\n' "$script"
  else
    printf '  FAIL %s\n' "$script" >&2
    fail=1
  fi
done

printf '\n== ShellCheck (when available) ==\n'
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "${scripts[@]}"; then
    printf '  ShellCheck passed.\n'
  else
    printf '  ShellCheck reported issues.\n' >&2
    fail=1
  fi
else
  printf '  shellcheck not installed; skipped.\n'
fi

printf '\n== Validation tests ==\n'
bash tests/test-validation.sh || fail=1

printf '\n== OS detection tests (fixtures + stubs) ==\n'
bash tests/test-os-detect.sh || fail=1

printf '\n== Firewall tests (stubbed commands) ==\n'
bash tests/test-firewall.sh || fail=1

if (( fail == 0 )); then
  printf '\nAll checks passed.\n'
else
  printf '\nSome checks failed.\n' >&2
fi
exit "$fail"
