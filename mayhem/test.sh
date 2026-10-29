#!/usr/bin/env bash
#
# mayhem/test.sh — RUN CLI known-answer checks plus upstream's smoke test (test/smoke.py) against the normal-flags pgbackrest that
# mayhem/build.sh built. It drives a real backup/restore cycle against the PostgreSQL installed in the
# image: initdb -> stanza-create -> check -> full backup -> load data -> incr backup -> wipe -> restore
# -> verify the restored row count. A no-op pgbackrest cannot pass it.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

EXE="$SRC/mayhem/build-test/src/pgbackrest"
[ -x "$EXE" ] || { echo "missing $EXE — mayhem/build.sh must build it" >&2; emit_ctrf "pgbackrest-smoke" 0 1; exit 1; }

# Known-input -> known-output checks of the CLI itself, run directly (no PostgreSQL needed).
cli_pass=0; cli_fail=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then cli_pass=$((cli_pass+1)); echo "PASS $1"
  else cli_fail=$((cli_fail+1)); echo "FAIL $1: expected [$2] got [$3]"; fi
}
version=$(sed -n "s/^    version: '\\([^']*\\)',/\\1/p" meson.build | head -1)
repo=$(mktemp -d)
mkdir -p "$repo/backup/demo"
printf 'hello-pgbackrest\n' > "$repo/backup/demo/hello.txt"
check "version"       "pgBackRest $version" "$("$EXE" version 2>&1)"
check "repo-ls"       "hello.txt"           "$("$EXE" --repo1-path="$repo" repo-ls backup/demo 2>&1)"
check "repo-get"      "hello-pgbackrest"    "$("$EXE" --repo1-path="$repo" repo-get backup/demo/hello.txt 2>&1)"
check "info-missing"  '[{"archive":[],"backup":[],"cipher":"none","db":[],"name":"demo","repo":[{"cipher":"none","key":1,"status":{"code":3,"message":"missing stanza data"}}],"status":{"code":3,"lock":{"backup":{"held":false},"restore":{"held":false}},"message":"missing stanza data"}}]' \
  "$("$EXE" --repo1-path="$repo" --stanza=demo info --output=json 2>&1)"
check "invalid-option" "P00  ERROR: [031]: option 'compress-level' not valid for command 'info'" \
  "$("$EXE" --repo1-path="$repo" --compress-level=99 info 2>&1)"
check "help-backup"   "pgBackRest $version - 'backup' command help" "$("$EXE" help backup 2>&1 | head -1)"
rm -rf "$repo"

out=$(python3 test/smoke.py --pgbackrest "$EXE" 2>&1)
rc=$?
printf '%s\n' "$out"

passed=$(printf '%s\n' "$out" | sed -n 's/^summary: \([0-9]*\) passed, \([0-9]*\) failed$/\1/p' | tail -1)
failed=$(printf '%s\n' "$out" | sed -n 's/^summary: \([0-9]*\) passed, \([0-9]*\) failed$/\2/p' | tail -1)
if [ -z "$passed" ] || [ -z "$failed" ]; then passed=0; failed=1; fi
[ "$rc" -eq 0 ] || [ "$failed" -gt 0 ] || failed=1
emit_ctrf "pgbackrest-cli+smoke" $((passed + cli_pass)) $((failed + cli_fail))
