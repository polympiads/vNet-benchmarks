#!/bin/bash
# Runs every scenario of bench.sh in the settings of the published results
# and writes the RESULT lines, under a header that describes the machine,
# to a file.
#
#   sudo ./run-matrix.sh <vNet source dir> <vNet build dir> [results file]
#
# BENCH_REPEAT [3] is the number of passes over the whole matrix. The
# default file is results/<date>-<cores>cpu.txt.
set -u

USAGE="usage: run-matrix.sh <vNet source dir> <vNet build dir> [results file]"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "${1:?$USAGE}" && pwd)"
BIN="$(cd "${2:?$USAGE}" && pwd)"
FILE="${3:-$HERE/results/$(date +%F)-$(nproc)cpu.txt}"
REPEAT="${BENCH_REPEAT:-3}"
mkdir -p "$(dirname "$FILE")"

{
  echo "# vNet benchmark results, $REPEAT passes"
  echo "# date:     $(date -u +%FT%TZ)"
  echo "# vNet:     commit $(git -c safe.directory='*' -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)," \
       "build type $(grep -s '^CMAKE_BUILD_TYPE' "$BIN/CMakeCache.txt" | cut -d= -f2)"
  echo "# cpu:      $(nproc) x$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2-)"
  echo "# memory:   $(awk '/MemTotal/ {printf "%.0f GB", $2 / 1048576}' /proc/meminfo)"
  echo "# kernel:   $(uname -r)"
  echo "# openssl:  $(openssl version | cut -d' ' -f1-2)"
  echo "# iperf3:   $(iperf3 --version | head -1 | cut -d' ' -f1-2)"
} > "$FILE"

# One scenario with its settings; its RESULT or FAIL line goes to the file.
run() {  # scenario, settings...
  local s=$1; shift
  env "$@" "$HERE/bench.sh" "$SRC" "$BIN" "$s" 2>&1 | grep -E '^(RESULT|FAIL)' | tee -a "$FILE"
}

for pass in $(seq 1 "$REPEAT"); do
  echo "# pass $pass" | tee -a "$FILE"
  run throughput
  run throughput BENCH_TLS=off
  run throughput BENCH_LIMITS=on
  for n in 100 200 400 800; do run join BENCH_MACHINES="$n"; done
  run config BENCH_MACHINES=300
  run config BENCH_MACHINES=5000
  run flood
done
echo "written to $FILE"
