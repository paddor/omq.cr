# Benchmarks

The benchmark surface is intentionally small. It measures one sender process
and one peer process over TCP loopback. It does not report in-process latency
or synthetic inproc throughput in README headlines. Output includes CPU model
because the absolute numbers are hardware-dependent.

```sh
crystal run --release --no-debug bench/tcp.cr
```

Default output covers:

- `PUSH`/`PULL` throughput for 128-byte payloads.
- `REQ`/`REP` round-trip latency for 128-byte payloads.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `OMQ_BENCH_SIZES` | `128` | Comma-separated payload sizes in bytes |
| `OMQ_BENCH_SECONDS` | `1.0` | Target seconds for throughput bursts |
| `OMQ_BENCH_ROUNDS` | `3` | Timed throughput rounds; fastest is reported |
| `OMQ_BENCH_MESSAGES` | unset | Force an exact throughput message count |
| `OMQ_BENCH_LATENCY_ITERS` | `10000` | Timed request/reply iterations |
| `OMQ_BENCH_LATENCY_WARMUP` | `1000` | Untimed request/reply warmup iterations |
