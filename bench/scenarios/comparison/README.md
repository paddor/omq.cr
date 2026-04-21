# Cross-implementation comparison

Same TCP-loopback workloads, four ZeroMQ implementations:

| Script | Language / runtime | Binding to wire |
|---|---|---|
| `omq.cr`    | Crystal 1.20 + omq.cr (this repo)            | Pure Crystal fibers |
| `pyzmq.py`  | CPython + [pyzmq](https://github.com/zeromq/pyzmq) | Cython → libzmq |
| `jeromq.rb` | JRuby + [JeroMQ](https://github.com/zeromq/jeromq) via Java interop | Pure Java NIO |
| `omq.rb`    | MRI + YJIT + [Ruby OMQ](https://github.com/paddor/omq) | Pure Ruby + async |

Each counterpart runs the identical workload:

- **PUSH/PULL** — 1 M messages after 10 k warmup, sizes 128 B and 1 KiB, single producer fiber/thread, single consumer
- **REQ/REP** — 100 k synchronous round-trips after 1 k warmup, sizes 128 B and 1 KiB, single REQ + single REP + echo loop

Transport is always `tcp://127.0.0.1` so every implementation hits its
own wire codec + socket path. Loopback is sensitive to CPU frequency
scaling and noisy-neighbor cores — pin the runs to the same hardware
profile before comparing, and treat single-digit deltas as noise.

## Running

```sh
./bench/scenarios/comparison/run.sh
```

The orchestrator runs whichever toolchains are on `$PATH`, prints a
section per counterpart, and skips missing ones with a one-line note
and an install hint. To run a single counterpart:

```sh
crystal run --release       bench/scenarios/comparison/omq.cr
python3                     bench/scenarios/comparison/pyzmq.py
ruby --yjit                 bench/scenarios/comparison/omq.rb

# JeroMQ: driven from JRuby via Java interop; jar auto-downloaded on first run.
# Clear RUBYOPT if you normally pass MRI-only flags (e.g. --yjit).
RUBYOPT="" jruby -J-cp jeromq-0.6.0.jar bench/scenarios/comparison/jeromq.rb
```

## Baseline results

Recorded on Linux 6.12 (Debian 13) inside a VM on a 2019 Intel MacBook
Pro; CPython 3.13.5 + pyzmq 26.4.0 (→ libzmq 4.3.5); Crystal 1.20;
JRuby 10.1.0.0 on JVM 21.0.10. The sample is small (one run each) —
treat these as ballpark, not as a benchmark of record. Rerun on your
own hardware and replace the table before drawing conclusions.

### PUSH/PULL throughput

| Implementation | 128 B msg/s | 128 B MB/s | 1 KiB msg/s | 1 KiB MB/s |
|---|---:|---:|---:|---:|
| omq.cr (pure Crystal)         | 879 k | 112 MB/s | 380 k | 390 MB/s |
| pyzmq (libzmq)                | 277 k |  35 MB/s | 255 k | 262 MB/s |
| JeroMQ (JRuby + Java interop) | 836 k | 107 MB/s | 549 k | 562 MB/s |
| Ruby OMQ (pure Ruby, YJIT)    | 366 k |  47 MB/s | 246 k | 251 MB/s |

### REQ/REP round-trip latency

| Implementation | 128 B µs/rtt | 1 KiB µs/rtt |
|---|---:|---:|
| omq.cr (pure Crystal)         |  14.3 µs |  14.2 µs |
| pyzmq (libzmq)                | 174.9 µs | 105.4 µs |
| JeroMQ (JRuby + Java interop) |  62.0 µs |  60.3 µs |
| Ruby OMQ (pure Ruby, YJIT)    |  66.1 µs |  72.3 µs |

### Notes on the sampled cells

- **pyzmq** uses OS threads with a blocking server loop (pyzmq's
  non-blocking poll path is slower still) — the `~175 µs` per round-trip
  is dominated by thread-context-switch cost on every reply, not wire
  or framing overhead. PUSH/PULL batches across syscalls so the gap
  there is much narrower.
- **omq.cr** keeps both endpoints in one process sharing the default
  Crystal fiber scheduler, so the REQ/REP echo avoids a kernel thread
  switch between the send and the reply. That accounts for most of the
  round-trip advantage on this specific workload shape.
- **JeroMQ** runs here under JRuby + Java interop rather than native
  `javac`/`java`, for symmetry with the Ruby OMQ counterpart (both are
  Ruby scripts; only the host VM differs). The interop overhead is
  small — the hot path is still JeroMQ's NIO threads in the JVM — but
  native JeroMQ would be marginally faster. Startup is dominated by
  JRuby + JVM warmup, not by the benchmark itself.
- **Ruby OMQ** trails the JVM counterparts by ~2× on PUSH/PULL and is
  in the same order of magnitude on REQ/REP. Pure-Ruby + YJIT is the
  honest apples-to-apples counterpart for omq.cr (same protocol
  implementation, same async-fiber shape), so the delta is a reasonable
  proxy for Crystal-vs-YJIT on this codec.

## Interpretation guide

- **throughput ≠ latency.** PUSH/PULL measures sustained streaming
  rate; REQ/REP measures round-trip pacing. Each workload stresses
  different parts of the stack (send pump batching vs. send/receive
  interleave, respectively).
- **pure-code implementations (omq.cr, JeroMQ, Ruby OMQ)** run the ZMTP
  codec in-process, so they don't pay the Cython/FFI boundary cost
  per message — but they pay the runtime's overhead (JIT warmup, GC,
  fiber scheduling) instead. Which wins depends on the workload.
- **libzmq (pyzmq, ffi-rzmq, CZTop)** runs the codec in a dedicated
  I/O thread pool in C. Small-message latency suffers from the IPC
  between application and I/O thread; large-message throughput
  approaches kernel limits.
- **The VM's IO event loop matters.** Crystal 1.20 uses libevent
  (epoll) by default, with optional io\_uring. Ruby's async can use
  io\_uring via io-event. JVM NIO uses epoll.
