#!/bin/bash
# Benchmarks for vNet (https://github.com/polympiads/vNet): the real
# conductor, switches and agents in Linux network namespaces on one
# machine, measured from the outside with iperf3 and ping.
#
#   sudo ./bench.sh <vNet source dir> <vNet build dir> <scenario> [...]
#
# Scenarios. Settings come from the environment, defaults in brackets.
#   throughput  One TCP stream and 200 pings from one agent to another,
#               each on its own switch, after a baseline on the same path
#               without vNet. BENCH_SECONDS [10]; BENCH_TLS=off runs every
#               link without TLS [on]; BENCH_LIMITS=on keeps the default
#               per-agent limits [off].
#   join        BENCH_MACHINES [200] agents started at once; time until
#               the conductor has registered the last one.
#   config      A config for BENCH_MACHINES [300] machines with four rules
#               each; time from SIGHUP on the conductor until both
#               switches have confirmed the new fingerprint.
#   flood       One agent sends BENCH_FLOOD_MBIT [300] Mbit/s of UDP for
#               5 s to an agent on the same switch, with per-agent limits
#               of 5000 packets/s and 50 Mbit/s; an agent on the other
#               switch pings the target 15 times meanwhile.
#
# Each scenario prints one line that starts with RESULT. Logs go to
# BENCH_OUT [./out]/<scenario>/.
#
# Needs root (namespaces, TUN devices), iproute2, iputils-ping, iperf3,
# openssl and bc. Everything runs on this machine, so the numbers are a
# floor for separate machines, and the links between namespaces lose no
# packets.
#
# Topology: namespace vb-core holds the conductor and routes between the
# others; vb-a1..vb-a3 hold agents, vb-s1 and vb-s2 hold switches, each
# joined to vb-core by a veth pair (core side .1, far side .2):
#   agents 172.31.<i>.2   switches 172.30.<i>.2
# Timers are vNet's defaults (heartbeat 10 s, dead after 30 s).

# The scenarios are called by name ("scenario_$s"), which shellcheck
# cannot follow.
# shellcheck disable=SC2329
set -u

USAGE="usage: bench.sh <vNet source dir> <vNet build dir> <scenario> [...]"
SRC="$(cd "${1:?$USAGE}" && pwd)"
BIN="$(cd "${2:?$USAGE}" && pwd)"
shift 2
[ $# -ge 1 ] || { echo "$USAGE"; exit 2; }

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 2; }
for tool in ip ping iperf3 openssl bc awk; do
  command -v "$tool" >/dev/null || { echo "missing $tool"; exit 2; }
done
for program in conductor switch agent; do
  [ -x "$BIN/$program" ] || { echo "no $program in $BIN"; exit 2; }
done
[ -x "$SRC/tools/vnet-certs.sh" ] || { echo "no tools/vnet-certs.sh in $SRC"; exit 2; }
for s in "$@"; do
  case "$s" in
    throughput|join|config|flood) ;;
    *) echo "unknown scenario '$s' (throughput, join, config, flood)"; exit 2 ;;
  esac
done

mkdir -p "${BENCH_OUT:-out}"
OUT="$(cd "${BENCH_OUT:-out}" && pwd)"
CERTS="$OUT/certs"
NSS="vb-core vb-a1 vb-a2 vb-a3 vb-s1 vb-s2"
TIMERS=(VNET_HEARTBEAT_SEC=10 VNET_DEAD_SEC=30)
declare -A PID
LOGS=""
FAILED=0

# ---------------------------------------------------------------- helpers

fail() { echo "FAIL $1: $2"; FAILED=1; }

# One certificate per role is enough: vNet checks the role, not the name.
make_certs() {
  [ -f "$CERTS/ca.pem" ] && return
  "$SRC/tools/vnet-certs.sh" init "$CERTS" >/dev/null
  local pair
  for pair in conductor:conductor switch:switch agent:agent; do
    "$SRC/tools/vnet-certs.sh" issue "$CERTS" "${pair%%:*}" "${pair##*:}" >/dev/null
  done
}

# Settings that put a process on TLS with the certificate of its role, or
# on plain TCP when BENCH_TLS=off.
link_env() {  # role
  if [ "${BENCH_TLS:-on}" = off ]; then echo "VNET_ALLOW_INSECURE=1"; return; fi
  echo "VNET_TLS=1 VNET_TLS_CA=$CERTS/ca.pem VNET_TLS_CERT=$CERTS/$1.pem VNET_TLS_KEY=$CERTS/$1.key"
}

in_ns() { local n=$1; shift; ip netns exec "vb-$n" "$@"; }

link() {  # namespace, first three octets of its subnet
  ip link add "vbx$1" type veth peer name "vbc$1"
  ip link set "vbx$1" netns "vb-$1"
  ip link set "vbc$1" netns vb-core
  in_ns core ip addr add "$2.1/24" dev "vbc$1"
  in_ns core ip link set "vbc$1" up
  in_ns "$1" ip addr add "$2.2/24" dev "vbx$1"
  in_ns "$1" ip link set "vbx$1" up
  in_ns "$1" ip route add default via "$2.1"
}

topo_up() {  # scenario name
  LOGS="$OUT/$1"
  rm -rf "$LOGS"; mkdir -p "$LOGS"
  local n
  for n in $NSS; do
    ip netns del "$n" 2>/dev/null
    ip netns add "$n"
    ip netns exec "$n" ip link set lo up
  done
  in_ns core sysctl -qw net.ipv4.ip_forward=1
  link a1 172.31.1; link a2 172.31.2; link a3 172.31.3
  link s1 172.30.1; link s2 172.30.2
}

topo_down() {
  local k n
  for k in "${!PID[@]}"; do kill "${PID[$k]}" 2>/dev/null; done
  wait 2>/dev/null
  PID=()
  for n in $NSS; do ip netns del "$n" 2>/dev/null; done
}
trap topo_down EXIT

# Three agents; agent1 may talk to agent2 and to agent3.
write_small_config() {
  printf 'agent1 10.0.1.1\nagent2 10.0.1.2\nagent3 10.0.1.3\nagent1 agent2\nagent1 agent3\n' > "$LOGS/switch.txt"
  printf 'switch switch1 key1\nswitch switch2 key2\nagent agent1 k1\nagent agent2 k2\nagent agent3 k3\n' > "$LOGS/auth.txt"
}

# The programs are started with ip directly, not through in_ns: a function
# in the background runs in a subshell, and $! would be that subshell
# instead of the program the signals are meant for.

# The conductor holds the switch config and sends it to the switches.
start_conductor() {
  # shellcheck disable=SC2046
  ip netns exec vb-core env "${TIMERS[@]}" $(link_env conductor) VNET_AUTH_FILE="$LOGS/auth.txt" \
      VNET_CONFIG_PATH="$LOGS/switch.txt" VNET_DUMP_PATH="$LOGS/dump.bin" \
      "$BIN/conductor" >> "$LOGS/conductor.log" 2>&1 &
  PID[conductor]=$!
}
start_switch() {  # index, extra settings...
  local i=$1; shift
  # shellcheck disable=SC2046
  ip netns exec "vb-s$i" env "${TIMERS[@]}" $(link_env switch) CONDUCTOR_IP="172.30.$i.1" CONDUCTOR_PORT=5000 \
      VNET_AUTH_KEY="key$i" VNET_STATS_SEC=0 "$@" "$BIN/switch" "switch$i" "600$i" >> "$LOGS/switch$i.log" 2>&1 &
  PID[switch$i]=$!
}
start_agent() {  # index, extra settings...
  local i=$1; shift
  # shellcheck disable=SC2046
  ip netns exec "vb-a$i" env "${TIMERS[@]}" $(link_env agent) CONDUCTOR_IP="172.31.$i.1" CONDUCTOR_PORT=5000 \
      VNET_AUTH_KEY="k$i" VNET_STATE_DIR="$LOGS/state" "$@" "$BIN/agent" "agent$i" >> "$LOGS/agent$i.log" 2>&1 &
  PID[agent$i]=$!
}

# wait_for <file> <pattern> <count> <seconds>
wait_for() {
  local deadline=$((SECONDS + $4))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(grep -c -- "$2" "$1" 2>/dev/null)" -ge "$3" ] && return 0
    sleep 0.2
  done
  return 1
}

# Mbit/s from the summary line of an iperf3 report on stdin.
mbit_of() {
  awk '{for (i=1;i<=NF;i++) if ($i ~ /bits\/sec/) {v=$(i-1); u=$i}} END {if (u ~ /^G/) v*=1000; if (u ~ /^K/) v/=1000; printf "%.0f", v}'
}

# Mean round trip in ms of 200 pings at 10 ms intervals.
mean_rtt() {  # namespace, address
  in_ns "$1" ping -c 200 -i 0.01 -q "$2" | grep rtt | cut -d= -f2 | cut -d/ -f2
}

now() { date +%s.%N; }

# ---------------------------------------------------------------- scenarios

scenario_throughput() {
  topo_up throughput
  write_small_config
  local dur=${BENCH_SECONDS:-10} limits=${BENCH_LIMITS:-off}
  local lim=() base base_rtt rtt mbit
  [ "$limits" = off ] && lim=(VNET_AGENT_PPS=0 VNET_AGENT_MBPS=0)

  # Baseline: the same two namespaces through the router, without vNet.
  in_ns a2 iperf3 -s -1 -p 5201 > /dev/null 2>&1 &
  sleep 0.3
  base=$(in_ns a1 iperf3 -c 172.31.2.2 -t 3 -p 5201 2>/dev/null | grep receiver | tail -1 | mbit_of)
  base_rtt=$(mean_rtt a1 172.31.2.2)

  # One agent per switch, placed by network name so the path is fixed.
  start_conductor; sleep 0.5
  start_switch 1 VNET_NETWORK=room1 ${lim[@]+"${lim[@]}"}
  start_switch 2 VNET_NETWORK=room2 ${lim[@]+"${lim[@]}"}
  wait_for "$LOGS/conductor.log" "applied config" 2 10 || { fail throughput "switches did not get the config"; return; }
  start_agent 1 VNET_NETWORK=room1
  start_agent 2 VNET_NETWORK=room2
  wait_for "$LOGS/conductor.log" "registered with IP" 2 20 || { fail throughput "agents did not register"; return; }
  sleep 1

  rtt=$(mean_rtt a1 10.0.1.2)
  in_ns a2 iperf3 -s -1 -p 5201 > "$LOGS/iperf-server.log" 2>&1 &
  sleep 0.5
  in_ns a1 iperf3 -c 10.0.1.2 -t "$dur" -p 5201 > "$LOGS/iperf.log" 2>&1
  mbit=$(grep receiver "$LOGS/iperf.log" | tail -1 | mbit_of)
  echo "RESULT throughput tls=${BENCH_TLS:-on} limits=$limits seconds=$dur" \
       "overlay_mbit=${mbit:-0} overlay_rtt_ms=${rtt:-?} baseline_mbit=${base:-0} baseline_rtt_ms=${base_rtt:-?}"
}

scenario_join() {
  topo_up join
  local n=${BENCH_MACHINES:-200} i tls t0 t1 launched got=0 deadline
  : > "$LOGS/switch.txt"
  printf 'switch switch1 key1\nswitch switch2 key2\n' > "$LOGS/auth.txt"
  for i in $(seq 1 "$n"); do
    printf 'm%04d 10.0.%d.%d\n' "$i" $((i / 250)) $((i % 250 + 1)) >> "$LOGS/switch.txt"
    printf 'agent m%04d k%d\n' "$i" "$i" >> "$LOGS/auth.txt"
  done
  ulimit -n 65536
  start_conductor; sleep 0.5
  start_switch 1; start_switch 2
  wait_for "$LOGS/conductor.log" "applied config" 2 10 || { fail join "switches did not get the config"; return; }

  # Every agent runs in namespace vb-a1 and keeps the namespace's default
  # route, so the agents do not fight over it.
  tls="$(link_env agent)"
  t0=$(now)
  # shellcheck disable=SC2086,SC2016
  ip netns exec vb-a1 bash -c '
    n=$1; bin=$2; logs=$3; shift 3
    for i in $(seq 1 "$n"); do
      env "$@" CONDUCTOR_IP=172.31.1.1 CONDUCTOR_PORT=5000 VNET_DEFAULT_VIA_TUN=0 \
          VNET_AUTH_KEY="k$i" VNET_STATE_DIR="$logs/state" \
          "$bin/agent" "$(printf m%04d "$i")" >> "$logs/agents.log" 2>&1 &
    done
    date +%s.%N > "$logs/launched"
    wait' _ "$n" "$BIN" "$LOGS" "${TIMERS[@]}" $tls &
  PID[agents]=$!
  deadline=$((SECONDS + 180))
  while [ "$SECONDS" -lt "$deadline" ]; do
    got=$(grep -c "registered with IP" "$LOGS/conductor.log")
    [ "$got" -ge "$n" ] && break
    sleep 0.05
  done
  t1=$(now)
  launched=$(cat "$LOGS/launched" 2>/dev/null || echo "$t0")
  echo "RESULT join machines=$n registered=$got seconds=$(echo "scale=2; ($t1 - $t0) / 1" | bc)" \
       "launch_seconds=$(echo "scale=2; ($launched - $t0) / 1" | bc)" \
       "switch1=$(grep -c "on switch switch1" "$LOGS/conductor.log")" \
       "switch2=$(grep -c "on switch switch2" "$LOGS/conductor.log")" \
       "rejected=$(grep -c Rejected "$LOGS/conductor.log")"
  [ "$got" -ge "$n" ] || fail join "only $got of $n machines registered"
  pkill -TERM -f "$BIN/agent m"; sleep 2; pkill -KILL -f "$BIN/agent m"
}

scenario_config() {
  topo_up config
  local n=${BENCH_MACHINES:-300} i t0 t1
  # One address and four rules per machine: three servers and a resolver.
  {
    for i in $(seq 1 "$n"); do printf 'p%04d 10.0.%d.%d\n' "$i" $((i / 250 + 1)) $((i % 250 + 1)); done
    for i in 1 2 3; do printf 'srv%d 10.0.0.%d\n' "$i" "$i"; done
    for i in $(seq 1 "$n"); do
      printf 'p%04d srv1\np%04d srv2\np%04d srv3\np%04d ::internet:192.0.2.53\n' "$i" "$i" "$i" "$i"
    done
  } > "$LOGS/switch.txt"
  printf 'switch switch1 key1\nswitch switch2 key2\n' > "$LOGS/auth.txt"
  start_conductor; sleep 0.5
  start_switch 1; start_switch 2
  wait_for "$LOGS/conductor.log" "applied config" 2 10 || { fail config "switches did not get the config"; return; }

  printf 'srv4 10.0.0.4\n' >> "$LOGS/switch.txt"
  t0=$(now)
  kill -HUP "${PID[conductor]}"
  while [ "$(grep -c 'applied config' "$LOGS/conductor.log")" -lt 4 ]; do
    [ "$(echo "$(now) - $t0 > 30" | bc)" = 1 ] && { fail config "switches did not confirm the reload"; return; }
    sleep 0.005
  done
  t1=$(now)
  echo "RESULT config machines=$n lines=$(wc -l < "$LOGS/switch.txt") bytes=$(wc -c < "$LOGS/switch.txt")" \
       "reload_to_confirmed_ms=$(echo "($t1 - $t0) * 1000 / 1" | bc)"
}

scenario_flood() {
  topo_up flood
  write_small_config
  local mbit=${BENCH_FLOOD_MBIT:-300} lim=(VNET_AGENT_PPS=5000 VNET_AGENT_MBPS=50)
  local iperf got limited
  # switch1 serves room1 (agent1, the target, and agent3, the flooder);
  # switch2 serves room2 (agent2, which pings the target).
  start_conductor; sleep 0.5
  start_switch 1 VNET_NETWORK=room1 "${lim[@]}"
  start_switch 2 VNET_NETWORK=room2 "${lim[@]}"
  wait_for "$LOGS/conductor.log" "applied config" 2 10 || { fail flood "switches did not get the config"; return; }
  start_agent 1 VNET_NETWORK=room1
  start_agent 2 VNET_NETWORK=room2
  start_agent 3 VNET_NETWORK=room1
  wait_for "$LOGS/conductor.log" "registered with IP" 3 20 || { fail flood "agents did not register"; return; }
  sleep 1

  in_ns a1 iperf3 -s -1 -p 5201 > "$LOGS/iperf-server.log" 2>&1 &
  sleep 0.5
  ip netns exec vb-a3 iperf3 -c 10.0.1.1 -u -b "${mbit}M" -l 1400 -t 5 -p 5201 > "$LOGS/iperf.log" 2>&1 &
  iperf=$!
  sleep 1
  got=$(in_ns a2 ping -c 15 -i 0.2 -W 1 10.0.1.1 2>/dev/null | grep -o '[0-9]* received' | cut -d' ' -f1)
  wait "$iperf"
  kill -USR1 "${PID[switch1]}" "${PID[switch2]}"; sleep 0.5
  limited=$(grep -h "Stats:" "$LOGS"/switch*.log | grep -o "rate-limited=[0-9]*" | cut -d= -f2 | paste -sd+ | bc)
  echo "RESULT flood offered_mbit=$mbit limit_pps=5000 limit_mbit=50" \
       "pings_answered=${got:-0}/15 rate_limited_packets=${limited:-0}"
}

# ---------------------------------------------------------------- main

[ "${BENCH_TLS:-on}" = off ] || make_certs
for s in "$@"; do
  topo_down
  "scenario_$s"
  topo_down
done
exit $FAILED
