#!/usr/bin/env bash
#
# mayhem/build.sh — build pgbackrest's three in-tree fuzz targets (test/fuzz: ini, json, pack), each
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
TARGETS="ini json pack"

# Leak detection off at build time (ASan/UBSan stay on and halting).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$M/lsan_off.c" -o "$M/build-lsan_off.o"

# Build the project and the fuzz targets with meson. Mirrors test/fuzz/build.sh upstream: debug build so
# asserts abort, sources compiled for the engine in use, engine link args handed to -Dfuzz-engine.
# $1 build dir, $2 extra compile flags, $3 link args of the engine
meson_fuzz() {
  rm -rf "$1"
  CFLAGS="$SANITIZER_FLAGS $2 $DEBUG_FLAGS" LDFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
    meson setup "$1" "$SRC" --buildtype=plain -Ddebug=true -Db_ndebug=false -Db_lundef=false \
      -Dfuzz-engine="$3 $M/build-lsan_off.o"
  meson compile -C "$1" -j "$MAYHEM_JOBS"
}

# 1) libFuzzer binaries
meson_fuzz "$M/build-fuzz" "-fsanitize=fuzzer-no-link" "$LIB_FUZZING_ENGINE"
for t in $TARGETS; do cp "$M/build-fuzz/test/fuzz-$t" "/mayhem/fuzz-$t"; done

# 2) standalone (non-fuzzer) reproducers: same sources linked with the run-once driver
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$M/build-standalone_main.o"
meson_fuzz "$M/build-standalone" "" "$M/build-standalone_main.o"
for t in $TARGETS; do cp "$M/build-standalone/test/fuzz-$t" "/mayhem/fuzz-$t-standalone"; done

# 3) the project's NORMAL-flags binary, for test.sh (upstream smoke test)
rm -rf "$M/build-test"
env -u CFLAGS -u LDFLAGS CFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" \
  meson setup "$M/build-test" "$SRC" --buildtype=release
meson compile -C "$M/build-test" -j "$MAYHEM_JOBS"
