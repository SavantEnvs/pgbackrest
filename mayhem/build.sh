#!/usr/bin/env bash
#
# mayhem/build.sh — build pgbackrest's JSON fuzz target (harness from upstream's later test/fuzz/json.c), each
# twice (libFuzzer + standalone reproducer), plus a normal-flags pgbackrest binary for mayhem/test.sh.
# Runs in the commit image as `mayhem` in /mayhem; offline-safe (all deps are apt -dev packages).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export CC CXX

cd "$SRC"
M="$SRC/mayhem"
TARGETS="json"

# Leak detection off at build time (ASan/UBSan stay on and halting).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$M/lsan_off.c" -o "$M/build-lsan_off.o"

# Build the project with meson (debug build so asserts abort, as upstream's own fuzz build), then link each
# harness (mayhem/harness: upstream's test/fuzz driver and targets, which this commit's meson.build predates)
# with the objects of the pgbackrest binary except main.c. The harness is compiled with the exact flags meson
# used for the project's sources, taken from compile_commands.json.
# $1 build dir, $2 extra compile flags, $3 link args of the engine
meson_fuzz() {
  rm -rf "$1"
  CFLAGS="$SANITIZER_FLAGS $2 $DEBUG_FLAGS" LDFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
    meson setup "$1" "$SRC" --buildtype=plain -Ddebug=true -Db_ndebug=false -Db_lundef=false
  meson compile -C "$1" -j "$MAYHEM_JOBS"
  python3 - "$1" "$3 $M/build-lsan_off.o" "$M/harness" "$TARGETS" <<'PY'
import json, os, shlex, subprocess, sys
build, engine, harness, targets = sys.argv[1:5]
cc = next(c for c in json.load(open(f"{build}/compile_commands.json")) if c["file"].endswith("src/common/memContext.c"))
flags, argv, skip = [], shlex.split(cc["command"]), 0
for a in argv[1:]:
    if skip: skip -= 1
    elif a in ("-MD",): pass
    elif a in ("-MQ", "-MF", "-o", "-c"): skip = 1
    elif a.startswith("-Isrc/pgbackrest.p") or a.startswith("-fdiagnostics-color"): pass
    else: flags.append(a)
link = shlex.split(subprocess.check_output(["ninja", "-C", build, "-t", "commands", "src/pgbackrest"], text=True).strip().splitlines()[-1])
objs = [a for a in link if a.endswith(".o") and not a.endswith("pgbackrest.p/main.c.o")]
rest = [a for a in link[1:] if not a.endswith(".o") and a not in ("-o", "src/pgbackrest")]
for t in targets.split():
    hobjs = []
    for src in ("fuzz.c", f"{t}.c"):
        o = f"src/fuzz-{t}.{src}.o"
        subprocess.check_call([argv[0], *flags, f"-I{harness}", "-c", f"{harness}/{src}", "-o", o], cwd=build)
        hobjs.append(o)
    subprocess.check_call([link[0], "-o", f"src/fuzz-{t}", *objs, *hobjs, *rest, *shlex.split(engine)], cwd=build)
PY
}

# 1) libFuzzer binaries
meson_fuzz "$M/build-fuzz" "-fsanitize=fuzzer-no-link" "$LIB_FUZZING_ENGINE"
for t in $TARGETS; do cp "$M/build-fuzz/src/fuzz-$t" "/mayhem/fuzz-$t"; done

# 2) standalone (non-fuzzer) reproducers: same sources linked with the run-once driver
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$M/build-standalone_main.o"
meson_fuzz "$M/build-standalone" "" "$M/build-standalone_main.o"
for t in $TARGETS; do cp "$M/build-standalone/src/fuzz-$t" "/mayhem/fuzz-$t-standalone"; done

# 3) the project's NORMAL-flags binary, for test.sh (upstream smoke test)
rm -rf "$M/build-test"
env -u CFLAGS -u LDFLAGS CFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" \
  meson setup "$M/build-test" "$SRC" --buildtype=release
meson compile -C "$M/build-test" -j "$MAYHEM_JOBS"
