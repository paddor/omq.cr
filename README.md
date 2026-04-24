# ØMQ — ZeroMQ for Crystal, no C required

[![License: ISC](https://img.shields.io/badge/License-ISC-blue.svg)](LICENSE)
[![Crystal](https://img.shields.io/badge/Crystal-%3E%3D%201.20-000000?logo=crystal&logoColor=white)](https://crystal-lang.org)

> **17.8M msg/s** inproc | **717k msg/s** ipc | **285k msg/s** tcp
>
> **0.5 µs** inproc round-trip | **9.4 µs** ipc | **12 µs** tcp
>
> Crystal 1.20 on a Linux VM, 128-byte payloads — see [`bench/`](bench/) for
> the full sweep

Add `omq` to your `shard.yml` and you're done. No libzmq, no FFI, no system
packages — just Crystal talking to every other ZeroMQ peer out there.

ØMQ gives your Crystal processes a way to talk to each other — and to
anything else speaking ZeroMQ — without a broker in the middle. The same
API works whether they live in the same process, on the same machine, or
across the network. Reconnects, queuing, and back-pressure are handled for
you; you write the interesting part.

This is the Crystal sibling of the pure-Ruby [omq](https://github.com/zeromq/omq)
gem. Same wire protocol (ZMTP 3.1, with 3.0 peer compat), same socket-type lineup, same bind/connect
semantics — ported to Crystal's fiber scheduler and libevent-backed event
loop.

## Highlights

- **Zero dependencies on C** — no FFI, no libzmq, no extensions. `shards
  install` just works everywhere Crystal runs
- **Fast** — Crystal-native `Channel` queues, direct-pipe inproc bypass,
  `TCP_NODELAY` on connect, work-stealing send pumps
- **No context object** — sockets are standalone; the Crystal runtime's
  fiber scheduler is the "context"
- **Every standard socket type** — REQ/REP, PUB/SUB, XPUB/XSUB, PUSH/PULL,
  DEALER/ROUTER, PAIR
- **Every transport** — `tcp://`, `ipc://` (Unix domain sockets, abstract
  namespace via leading `@`), `inproc://` (in-process channel pairs)
- **Wire-compatible** — interoperates with libzmq, pyzmq, CZMQ, JeroMQ,
  and the Ruby `omq` gem over TCP and IPC
- **Bind/connect order doesn't matter** — connect before bind, bind before
  connect, peers come and go. Reconnect is automatic; buffered messages
  flush when a peer arrives

## Install

```yaml
# shard.yml
dependencies:
  omq:
    github: paddor/omq.cr
```

Then `shards install`. Crystal ≥ 1.20 is required.

## Quick start

### Request / Reply

```crystal
require "omq"

rep = OMQ::REP.bind("inproc://example")
req = OMQ::REQ.connect("inproc://example")

spawn do
  msg = rep.receive
  rep.send(msg.map { |p| String.new(p).upcase })
end

req.send("hello")
pp req.receive.map { |p| String.new(p) }
# => ["HELLO"]

req.close
rep.close
```

### Pub / Sub

```crystal
pub = OMQ::PUB.bind("inproc://pubsub")
sub = OMQ::SUB.connect("inproc://pubsub")
sub.subscribe("")  # subscribe to everything

spawn { pub.send("news flash") }
pp sub.receive.map { |p| String.new(p) }
# => ["news flash"]
```

### Push / Pull (pipeline)

```crystal
pull = OMQ::PULL.bind("inproc://work")
push = OMQ::PUSH.connect("inproc://work")

push.send("work item")
pp pull.receive.map { |p| String.new(p) }
# => ["work item"]
```

### TCP

Same API, just swap the endpoint — ephemeral ports via `:0`:

```crystal
pull = OMQ::PULL.new
pull.bind("tcp://127.0.0.1:0")
port = pull.port

push = OMQ::PUSH.new
push.connect("tcp://127.0.0.1:#{port}")

push.send("hello over the network")
pp pull.receive
```

## Socket types

All sockets are fiber-safe. Default HWM is 1000 messages per socket.
Classes live under `OMQ::`.

| Pattern | Send | Receive | When HWM full |
|---------|------|---------|---------------|
| **REQ** / **REP** | Work-stealing / route-back | Fair-queue | Block |
| **PUB** / **SUB** | Fan-out to subscribers | Local subscription filter | Configurable (Block / DropNewest / DropOldest) |
| **XPUB** / **XSUB** | Fan-out / broadcast | Subscribe events / no filter | Configurable (XPUB) |
| **PUSH** / **PULL** | Work-stealing to workers | Fair-queue | Block |
| **DEALER** / **ROUTER** | Work-stealing / identity-route | Fair-queue | Block |
| **PAIR** | Exclusive 1-to-1 | Exclusive 1-to-1 | Block |

Set options between `.new` and the first `.bind`/`.connect`:

```crystal
sub = OMQ::SUB.new
sub.recv_hwm = 10_000
sub.read_timeout = 500.milliseconds
sub.connect("tcp://server:5555")
```

### Endpoint prefix convention

- `"@tcp://…"` — bind
- `">tcp://…"` — connect
- plain `"tcp://…"` — use the socket-type default (`PUSH`→connect,
  `PULL`→bind, `PUB`→bind, `SUB`→connect, …)

## Options

| Option | Default | Meaning |
|---|---|---|
| `send_hwm` / `recv_hwm` | 1000 | Messages buffered per socket before backpressure/drop kicks in |
| `linger` | `0.seconds` | Close-time drain budget; `nil` = wait forever |
| `identity` | `""` | Peer identity advertised in the ZMTP READY command |
| `read_timeout` / `write_timeout` | `nil` | Raise `IO::TimeoutError` after this span |
| `reconnect_interval` | `100.milliseconds` | Fixed span, or `Range(Time::Span, Time::Span)` for exponential backoff |
| `heartbeat_interval` / `heartbeat_ttl` / `heartbeat_timeout` | `nil` | ZMTP PING/PONG keepalive + silent-peer watchdog |
| `max_message_size` | `nil` | Drop the connection if a frame exceeds this many bytes |
| `sndbuf` / `rcvbuf` | `nil` | Kernel socket buffer sizes (TCP/IPC only) |
| `conflate` | `false` | PUB only: keep only the latest message under pressure |
| `on_mute` | `:block` | PUB only: `:block`, `:drop_newest`, `:drop_oldest` |

## Benchmarks

```sh
crystal run --release bench/run_all.cr
```

Writes one JSONL line per (pattern, transport, size, peers) to
`bench/results.jsonl`. Regenerate the tables in [`bench/README.md`](bench/README.md)
with:

```sh
crystal run --release bench/report.cr -- --update-readme
```

The `bench/scenarios/comparison/` directory runs the same PUSH/PULL +
REQ/REP workload against pyzmq, JeroMQ, and Ruby OMQ for side-by-side
comparison.

## Status

Pre-1.0. All 12 standard socket types work, inproc/ipc/tcp all work,
heartbeat/linger/reconnect/HWM/on_mute/conflate/max_message_size/sndbuf/rcvbuf
are wired through. Draft socket types (CLIENT/SERVER, RADIO/DISH,
SCATTER/GATHER, PEER, CHANNEL), CURVE encryption (opt-in via `require
"omq/curve"`), and the monitor-event API all work — see
[`CHANGELOG.md`](CHANGELOG.md).

## CURVE encryption

Opt-in; depends on the [`natron`](https://github.com/paddor/natron.cr)
libsodium wrapper. Add it to your shard.yml alongside `omq`, then:

```crystal
require "omq"
require "omq/curve"

server_sk = Natron::PrivateKey.generate
server_pk = server_sk.public_key

rep = OMQ::REP.new
rep.mechanism = OMQ::ZMTP::Mechanism::Curve.server(
  public_key: server_pk.bytes, secret_key: server_sk.bytes)
rep.bind("tcp://127.0.0.1:5555")

client_sk = Natron::PrivateKey.generate
req = OMQ::REQ.new
req.mechanism = OMQ::ZMTP::Mechanism::Curve.client(
  server_key: server_pk.bytes,
  public_key: client_sk.public_key.bytes,
  secret_key: client_sk.bytes)
req.connect("tcp://127.0.0.1:5555")
```

Pass an authenticator proc to the server factory to whitelist client
public keys.

## Development

```sh
shards install
crystal run test/run.cr
```

The full suite runs in ~2 seconds. Add a new test file under
`test/omq/*_test.cr` — `test/run.cr` auto-discovers everything.

## License

[ISC](LICENSE)
