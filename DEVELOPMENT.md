# Development

## Setup

```sh
shards install
```

`shard.yml` uses sibling `../natron.cr` for dev tests. Keep that checkout
present when running full test suite.

## Build And Format

```sh
/usr/bin/crystal tool format src test bench examples
/usr/bin/crystal build --release --no-debug bench/lz4_push_pull/omq.cr \
  -o bin/omq-cr-lz4-pushpull-bench
```

Do not benchmark with compiler warnings or format churn.

## Tests

```sh
/usr/bin/crystal run test/run.cr
```

System interop tests use Ruby OMQ. They skip when Ruby or required gem
features are missing. Use this Ruby locally:

```sh
OMQ_RUBY_BIN=/home/roadster/.rubies/ruby-4.0.6/bin/ruby \
  /usr/bin/crystal run test/system/run.cr
```

Narrow tests by running target files directly:

```sh
/usr/bin/crystal run test/omq/lz4_tcp_test.cr
/usr/bin/crystal run test/system/interop_lz4_tcp_test.cr
```

## Benchmarks

Never run benchmarks or profilers in parallel. Stop if any benchmark
prints warnings or timeouts. Fix first, rerun after.

Main in-process and transport benchmarks:

```sh
/usr/bin/crystal run --release --no-debug bench/run_all.cr
/usr/bin/crystal run bench/report.cr
/usr/bin/crystal run bench/report.cr -- --update-readme
```

Single pattern:

```sh
/usr/bin/crystal run --release --no-debug bench/push_pull/omq.cr
```

Common knobs: `OMQ_BENCH_TRANSPORTS`, `OMQ_BENCH_SIZES`,
`OMQ_BENCH_PEERS`, `OMQ_BENCH_TARGET`, `OMQ_BENCH_TIMEOUT`.
Default output: `bench/results.jsonl`.

## 2-Process TCP Benchmark

OMQ.rs-style TCP process benchmark:

- 1 PUSH process -> 2 PULL sockets
- 1 PUB process -> 4 and 16 SUB sockets
- 1 REQ process <-> 1 REP process

```sh
/usr/bin/crystal run --release --no-debug bench/tcp_process/omq.cr
```

Knobs: `OMQ_BENCH2_SIZES`, `OMQ_BENCH2_LATENCY_SIZES`,
`OMQ_BENCH2_PUBSUB_PEERS`, `OMQ_BENCH2_TARGET`,
`OMQ_BENCH2_ROUNDS`, `OMQ_BENCH2_OUTPUT`.

Default output: `~/.cache/omq/omq-cr-tcp-process.jsonl`.

## LZ4 PUSH/PULL Benchmark

OMQ.rs-style 2-process PUSH/PULL compression benchmark. It runs:

- `tcp`
- `lz4+tcp`
- `lz4+tcp` with Flint-trained 2 KiB dictionary

Payloads are synthetic JSON records. Dictionary samples use the same
size bias as omq.rs.

```sh
/usr/bin/crystal run --release --no-debug bench/lz4_push_pull/omq.cr
```

Quick smoke:

```sh
OMQ_BENCH_LZ4_SIZES=64,1024 \
  OMQ_BENCH_LZ4_TARGET=0.2 \
  OMQ_BENCH_LZ4_ROUNDS=1 \
  /usr/bin/crystal run --release --no-debug bench/lz4_push_pull/omq.cr
```

Knobs: `OMQ_BENCH_LZ4_SIZES`, `OMQ_BENCH_LZ4_TARGET`,
`OMQ_BENCH_LZ4_ROUNDS`, `OMQ_BENCH_LZ4_DICT`,
`OMQ_BENCH_LZ4_OUTPUT`.

Default output: `~/.cache/omq.cr/lz4-pushpull.jsonl`.
