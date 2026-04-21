# Benchmarks

Pure-Crystal OMQ throughput and round-trip latency.

Each cell is the fastest of N timed rounds (~1 s each) after a calibration
warmup, so transient scheduler/GC jitter is filtered out. Between-run
variance on the same machine is ~5-15 % depending on transport; treat
single-digit deltas across runs as noise.

### Reading the numbers (\*)

The same `Bytes` payload is reused across every send — no per-message
allocation. The primary metric is **msg/s** (raw send-path throughput,
what the library can actually push through its queues and codec). The
**MB/s\*** figures are nominal — they're `msg/s × msg_size`, which for
inproc overstates real memory bandwidth (inproc passes `Bytes` by
reference through a `Channel(Message)` — no bytes are copied). For
IPC/TCP the bytes really do traverse the kernel, so MB/s there is
meaningful within kernel-buffer/loopback limits. Cross-impl comparison
is fairer this way: Ruby's `String#dup` is copy-on-write while Crystal's
`Bytes#dup` is a real memcpy, so a `.dup`-per-send bench would compare
allocator speed rather than send speed.

Regenerate the tables below from the latest run in `results.jsonl`:

```sh
crystal run --release bench/report.cr -- --update-readme
```

## Throughput (PUSH/PULL, msg/s)

```
┌──────┐       ┌──────┐
│ PUSH │──────→│ PULL │
└──────┘       └──────┘
```

<!-- BEGIN push_pull -->
### 1 peer

| Message size | inproc | ipc | tcp |
|---|---|---|---|
| 128 B | 17.83M msg/s / 2.28 GB/s* | 717.2k msg/s / 91.8 MB/s* | 285.0k msg/s / 36.5 MB/s* |
| 512 B | 18.38M msg/s / 9.41 GB/s* | 592.4k msg/s / 303 MB/s* | 286.3k msg/s / 147 MB/s* |
| 2 KiB | 17.65M msg/s / 36.15 GB/s* | 424.4k msg/s / 869 MB/s* | 200.6k msg/s / 411 MB/s* |
| 8 KiB | 18.37M msg/s / 150.51 GB/s* | 225.0k msg/s / 1.84 GB/s* | 121.4k msg/s / 995 MB/s* |
| 32 KiB | 17.95M msg/s / 588.10 GB/s* | 57.1k msg/s / 1.87 GB/s* | 38.1k msg/s / 1.25 GB/s* |

### 3 peers

| Message size | inproc | ipc | tcp |
|---|---|---|---|
| 128 B | 17.97M msg/s / 2.30 GB/s* | 694.2k msg/s / 88.9 MB/s* | 630.3k msg/s / 80.7 MB/s* |
| 512 B | 16.96M msg/s / 8.68 GB/s* | 573.6k msg/s / 294 MB/s* | 223.5k msg/s / 114 MB/s* |
| 2 KiB | 17.01M msg/s / 34.83 GB/s* | 357.5k msg/s / 732 MB/s* | 172.3k msg/s / 353 MB/s* |
| 8 KiB | 16.75M msg/s / 137.18 GB/s* | 150.8k msg/s / 1.24 GB/s* | 91.0k msg/s / 745 MB/s* |
| 32 KiB | 17.69M msg/s / 579.64 GB/s* | 54.8k msg/s / 1.80 GB/s* | 32.6k msg/s / 1.07 GB/s* |

<!-- END push_pull -->

## Round-trip latency (REQ/REP, µs)

```
┌─────┐  req   ┌─────┐
│ REQ │───────→│ REP │
│     │←───────│     │
└─────┘  rep   └─────┘
```

Round-trip = one `req.send` + one `req.receive` + matching `rep` ops.
Latency is `1 / msgs_s` converted to µs.

<!-- BEGIN req_rep -->
| Message size | inproc | ipc | tcp |
|---|---|---|---|
| 128 B | 0.54 µs | 9.42 µs | 12.1 µs |
| 512 B | 0.57 µs | 7.73 µs | 13.0 µs |
| 2 KiB | 0.50 µs | 8.92 µs | 15.5 µs |
| 8 KiB | 0.53 µs | 15.5 µs | 33.3 µs |
| 32 KiB | 0.60 µs | 29.3 µs | 60.8 µs |

<!-- END req_rep -->

## Throughput (ROUTER/DEALER, msg/s)

```
┌────────┐       ┌────────┐
│ DEALER │──────→│ ROUTER │
└────────┘       └────────┘
```

DEALER peers identified by a short string (`d0`, `d1`, …). ROUTER receives
each frame prefixed with the originator's identity.

<!-- BEGIN router_dealer -->
### 3 peers

| Message size | inproc | ipc | tcp |
|---|---|---|---|
| 128 B | 10.04M msg/s / 1.28 GB/s* | 667.9k msg/s / 85.5 MB/s* | 408.1k msg/s / 52.2 MB/s* |
| 512 B | 10.49M msg/s / 5.37 GB/s* | 587.4k msg/s / 301 MB/s* | 433.7k msg/s / 222 MB/s* |
| 2 KiB | 9.63M msg/s / 19.72 GB/s* | 359.2k msg/s / 736 MB/s* | 178.3k msg/s / 365 MB/s* |
| 8 KiB | 9.75M msg/s / 79.87 GB/s* | 164.1k msg/s / 1.34 GB/s* | 86.4k msg/s / 708 MB/s* |
| 32 KiB | 9.84M msg/s / 322.50 GB/s* | 70.4k msg/s / 2.31 GB/s* | 30.4k msg/s / 996 MB/s* |

<!-- END router_dealer -->

## Throughput (PUB/SUB, msg/s)

```
           ┌─────┐
         ┌→│ SUB │
┌─────┐  │ └─────┘
│ PUB │──┤
└─────┘  │ ┌─────┐
         └→│ SUB │
           └─────┘
```

All subs subscribe to the empty prefix; PUB sends N messages and each SUB
receives all N. `msg/s` is the publish rate, not the fan-out total.

<!-- BEGIN pub_sub -->
### 3 peers

| Message size | inproc | ipc | tcp |
|---|---|---|---|
| 128 B | 4.91M msg/s / 629 MB/s* | 221.0k msg/s / 28.3 MB/s* | 83.3k msg/s / 10.7 MB/s* |
| 512 B | 4.68M msg/s / 2.40 GB/s* | 202.4k msg/s / 104 MB/s* | 122.7k msg/s / 62.8 MB/s* |
| 2 KiB | 4.87M msg/s / 9.97 GB/s* | 117.5k msg/s / 241 MB/s* | 92.0k msg/s / 188 MB/s* |
| 8 KiB | 4.79M msg/s / 39.27 GB/s* | 65.2k msg/s / 534 MB/s* | 36.5k msg/s / 299 MB/s* |
| 32 KiB | 4.60M msg/s / 150.57 GB/s* | 20.0k msg/s / 656 MB/s* | 10.0k msg/s / 328 MB/s* |

<!-- END pub_sub -->

## Throughput (PAIR, msg/s)

```
┌──────┐       ┌──────┐
│ PAIR │──────→│ PAIR │
└──────┘       └──────┘
```

Exclusive 1-to-1 pipe with no routing logic — the throughput ceiling for
the transport.

<!-- BEGIN pair -->
### 1 peer

| Message size | inproc | ipc | tcp |
|---|---|---|---|
| 128 B | 26.53M msg/s / 3.40 GB/s* | 736.4k msg/s / 94.3 MB/s* | 250.2k msg/s / 32.0 MB/s* |
| 512 B | 27.20M msg/s / 13.93 GB/s* | 634.2k msg/s / 325 MB/s* | 308.0k msg/s / 158 MB/s* |
| 2 KiB | 25.33M msg/s / 51.88 GB/s* | 409.5k msg/s / 839 MB/s* | 214.6k msg/s / 440 MB/s* |
| 8 KiB | 26.46M msg/s / 216.80 GB/s* | 192.2k msg/s / 1.57 GB/s* | 144.9k msg/s / 1.19 GB/s* |
| 32 KiB | 27.77M msg/s / 910.10 GB/s* | 66.3k msg/s / 2.17 GB/s* | 39.6k msg/s / 1.30 GB/s* |

<!-- END pair -->

## Running

```sh
# Full suite — one RUN_ID shared across all patterns
crystal run --release bench/run_all.cr

# Single pattern
crystal run --release bench/push_pull/omq.cr

# Regression report (latest vs previous run)
crystal run bench/report.cr

# Regenerate README tables from the latest run
crystal run bench/report.cr -- --update-readme

# Full comparison table for the last 5 runs
crystal run bench/report.cr -- --runs 5 --all

# Narrow a run: transports, payload sizes, peer counts, target seconds
OMQ_BENCH_TRANSPORTS=inproc \
  OMQ_BENCH_SIZES=128,1024 \
  OMQ_BENCH_PEERS=1 \
  OMQ_BENCH_TARGET=0.5 \
  crystal run --release bench/push_pull/omq.cr
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `OMQ_BENCH_TRANSPORTS` | `inproc,ipc,tcp` | Comma-separated transports to run |
| `OMQ_BENCH_SIZES` | `128,512,2048,8192,32768` | Payload sizes in bytes |
| `OMQ_BENCH_PEERS` | per-pattern default (`[1,3]` or `[1]`) | Peer counts to run |
| `OMQ_BENCH_TARGET` | `1.0` | Target seconds per timed burst |
| `OMQ_BENCH_TIMEOUT` | `30` | Per-cell hard timeout in seconds |
| `OMQ_BENCH_RUN_ID` | ISO timestamp | Shared key so patterns correlate across one run |
