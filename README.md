# vNet benchmarks

Scenarios that measure [vNet](https://github.com/polympiads/vNet), the
overlay network for on-site programming contests. They start the real
conductor, switches and agents in Linux network namespaces on one machine
and measure them from the outside with `iperf3` and `ping`.

## What is measured

| Scenario | Question it answers |
| --- | --- |
| `throughput` | How fast is one TCP stream between two agents on different switches, and how much latency does the overlay add? |
| `join` | How long until a room of machines that start at the same time is attached? |
| `config` | How long does a rule change take to reach every switch? |
| `flood` | Does a machine that floods its switch hurt the others? |

## Running

Build vNet in release mode, then point the script at the source tree (for
its certificate tool) and at the build directory (for the three programs).

```
git clone https://github.com/polympiads/vNet
cmake -S vNet -B vNet/build -DCMAKE_BUILD_TYPE=Release
cmake --build vNet/build --target conductor switch agent

sudo ./bench.sh vNet vNet/build throughput join config flood
```

It needs root (namespaces, TUN devices), `iproute2`, `iputils-ping`,
`iperf3`, `openssl` and `bc`. Each scenario prints one line that starts
with `RESULT`; logs go to `out/<scenario>/`.

`sudo ./run-matrix.sh vNet vNet/build` runs every scenario in the
settings of the results below, three times, and writes the lines to
`results/<date>-<cores>cpu.txt` under a header that describes the machine.

## Settings

| Variable | Default | Scenario | Meaning |
| --- | --- | --- | --- |
| `BENCH_SECONDS` | 10 | throughput | Length of the TCP stream. |
| `BENCH_TLS` | on | throughput | `off` runs every vNet link without TLS. |
| `BENCH_LIMITS` | off | throughput | `on` keeps vNet's default per-agent limits (20000 packets/s, 200 Mbit/s). |
| `BENCH_MACHINES` | 200, 300 | join, config | Number of machines that join, or that the config describes. |
| `BENCH_FLOOD_MBIT` | 300 | flood | Offered UDP load. |
| `BENCH_OUT` | out | all | Directory for logs and test certificates. |

## The scenarios in detail

**throughput.** Two agents, one per switch, so a packet crosses agent,
switch, switch, agent. The scenario first measures the same two namespaces
through the router without vNet (3 s of TCP, 200 pings), then starts vNet
and measures again (`BENCH_SECONDS` of TCP, 200 pings at 10 ms intervals).

**join.** The conductor and two switches are up. All agents are started
from one shell loop in one namespace, with one shared agent certificate.
The time runs from the first start to the moment the conductor has
registered the last machine, so it includes starting the agent processes.
Every join is two mutually authenticated TLS handshakes.

**config.** The conductor holds a config with one address and four rules
per machine. One line is appended and the conductor gets SIGHUP. The time
runs until both switches have confirmed the new fingerprint.

**flood.** Per-agent limits are 5000 packets/s and 50 Mbit/s. One agent
sends UDP at `BENCH_FLOOD_MBIT` for 5 s to an agent on the same switch,
while an agent on the other switch pings the target 15 times. The line
reports the pings answered and the packets the switches dropped for the
rate limit.

## Results

From `results/2026-11-10-2cpu.txt`: vNet commit 3074ec9 in release mode on
a virtual machine with 2 cores of an Intel Xeon at 2.1 GHz and 8 GB of
memory, Linux 6.18, OpenSSL 3.0.13, iperf 3.16. Three passes; ranges are
the lowest and highest value.

| Measurement | Result |
| --- | --- |
| TCP between two agents, TLS, no per-agent limit | 640 to 666 Mbit/s |
| The same without TLS | 1030 to 1080 Mbit/s |
| The same with TLS and the default limit of 200 Mbit/s | 212 Mbit/s |
| The same path without vNet | 15800 to 17700 Mbit/s |
| Mean ping round trip through vNet, TLS, no limit | 0.42 to 0.50 ms |
| Mean ping round trip without vNet | 0.02 ms |
| 100 machines joining at once | 1.02 to 1.09 s |
| 200 machines | 2.03 to 2.11 s |
| 400 machines | 4.00 to 4.31 s |
| 800 machines | 8.32 to 8.63 s |
| Config change, 300 machines (1504 lines, 23 KB) | 15 ms |
| Config change, 5000 machines (25004 lines, 391 KB) | 62 to 74 ms |
| Pings answered by a machine under a 300 Mbit/s flood | 15 of 15 |
| Packets dropped by the rate limit during that flood | 107653 to 107658 |

## Reading the numbers

Every process of a run shares the cores of one machine: the conductor,
both switches, the agents and the load generators. The numbers are a floor
for a deployment on separate machines, not a prediction of it.

The links between the namespaces lose no packets and add no delay. vNet
carries packets inside TCP connections, so a network with loss is the
condition it handles worst, and these scenarios do not show it.

In the join scenario every machine split evenly between the two switches
and no join was refused. In the flood scenario the byte limit predicts
about 107670 dropped packets for that load (26786 packets/s offered,
4377 packets/s allowed, one second of burst), so the limiter is exact to
within a few packets in a hundred thousand.
