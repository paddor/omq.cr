# ØMQ - ZeroMQ for Crystal, no C required

[![License: ISC](https://img.shields.io/badge/License-ISC-blue.svg)](LICENSE)
[![Crystal](https://img.shields.io/badge/Crystal-%3E%3D%201.21-000000?logo=crystal&logoColor=white)](https://crystal-lang.org)

> **17.8M msg/s** inproc | **717k msg/s** ipc | **285k msg/s** tcp
>
> **0.5 µs** inproc round-trip | **9.4 µs** ipc | **12 µs** tcp
>
> Crystal 1.21 on a Linux VM, 128-byte payloads. See [`bench/`](bench/) for
> the full sweep

Add `omq` to your `shard.yml` and you're done. No libzmq, no FFI, no system
packages. Just Crystal talking to every other ZeroMQ peer out there.

ØMQ gives your Crystal processes a way to talk to each other and to
anything else speaking ZeroMQ without a broker in the middle. The same
API works whether they live in the same process, on the same machine, or
across the network. Reconnects, queuing, and back-pressure are handled for
you; you write the interesting part.

This is the Crystal sibling of the pure-Ruby [omq](https://github.com/zeromq/omq)
gem. Same wire protocol (ZMTP 3.1, with 3.0 peer compat), same socket-type lineup, same bind/connect
semantics. Ported to Crystal's fiber scheduler and libevent-backed event
loop.

## Highlights

- **Zero dependencies on C**: no FFI, no libzmq, no extensions. `shards
  install` just works everywhere Crystal runs
- **Fast**: Crystal-native `Channel` queues, direct-pipe inproc bypass,
  `TCP_NODELAY` on connect, work-stealing send pumps
- **No context object**: sockets are standalone; the Crystal runtime's
  fiber scheduler is the "context"
- **Every standard socket type**: REQ/REP, PUB/SUB, XPUB/XSUB, PUSH/PULL,
  DEALER/ROUTER, PAIR
- **Every transport**: `tcp://`, `udp://`, `lz4+tcp://`, `zstd+tcp://`,
  `ipc://` (Unix domain sockets, abstract namespace via leading `@`),
  `inproc://` (in-process channel pairs)
- **Security mechanisms**: NULL by default, PLAIN username/password auth,
  CURVE encryption via `require "omq/curve"`
- **Wire-compatible**: interoperates with libzmq, pyzmq, CZMQ, JeroMQ,
  and the Ruby `omq`, `omq-lz4`, and `omq-zstd` gems
- **Bind/connect order doesn't matter**: connect before bind, bind before
  connect, peers come and go. Reconnect is automatic; buffered messages
  flush when a peer arrives

## Install

```yaml
# shard.yml
dependencies:
  omq:
    github: paddor/omq.cr
```

Then `shards install`. Crystal ≥ 1.21 is required.

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

Same API, just swap the endpoint. Ephemeral ports via `:0`:

```crystal
pull = OMQ::PULL.new
pull.bind("tcp://127.0.0.1:0")
port = pull.port

push = OMQ::PUSH.new
push.connect("tcp://127.0.0.1:#{port}")

push.send("hello over the network")
pp pull.receive
```

### LZ4 TCP

Use `lz4+tcp://` when payloads have repeated structure and bandwidth
matters. Handshake and ZMTP commands stay raw. Data frames get a small
LZ4 envelope and remain wire-compatible with Ruby `omq-lz4`.

```crystal
pull = OMQ::PULL.bind("lz4+tcp://127.0.0.1:0")
push = OMQ::PUSH.connect("lz4+tcp://127.0.0.1:#{pull.port}")

push.send("hello, compressed world")
pp pull.receive
```

Send-side dictionaries are supported. They are shipped once per direction
on each connection. `auto_dict: true` trains from early outgoing messages.

```crystal
dict = File.read("schema.dict").to_slice
push.connect("lz4+tcp://127.0.0.1:5555", dict: dict)

push.connect("lz4+tcp://127.0.0.1:5556", auto_dict: true)
```

### Zstd TCP

Use `zstd+tcp://` for larger repeated payloads or when Zstd dictionaries are
already part of your wire contract. Handshake and ZMTP commands stay raw.
Data frames use the Ruby `omq-zstd` envelope.

```crystal
pull = OMQ::PULL.bind("zstd+tcp://127.0.0.1:0")
push = OMQ::PUSH.connect("zstd+tcp://127.0.0.1:#{pull.port}")

push.send("hello, zstd world")
pp pull.receive
```

Send-side ZDICT dictionaries are shipped once per direction on each
connection. `zstd_auto_dict: true` trains from early outgoing messages.

```crystal
dict = File.read("schema.zdict").to_slice
push.connect("zstd+tcp://127.0.0.1:5555", zstd_dict: dict, zstd_level: 6)

push.connect("zstd+tcp://127.0.0.1:5556", zstd_auto_dict: {capacity: 2048, max_samples: 50})
```

## Socket types

All sockets are fiber-safe. Default HWM is 1000 messages per socket.
Classes live under `OMQ::`.

| Pattern | Send | Receive | When HWM full |
|---------|------|---------|---------------|
| **REQ** / **REP** | Work-stealing / route-back | Fair-queue | Block |
| **PUB** / **SUB** | Fan-out to subscribers | Local subscription filter | DropNewest by default; configurable |
| **XPUB** / **XSUB** | Fan-out / broadcast | Subscribe events / no filter | DropNewest by default on XPUB; configurable |
| **PUSH** / **PULL** | Work-stealing to workers | Fair-queue | Block |
| **DEALER** / **ROUTER** | Work-stealing / identity-route | Fair-queue | Block |
| **STREAM** | Identity-route raw TCP | Identity-prefixed raw TCP | Block |
| **PAIR** | Exclusive 1-to-1 | Exclusive 1-to-1 | Block |

Set options between `.new` and the first `.bind`/`.connect`:

```crystal
sub = OMQ::SUB.new
sub.recv_hwm = 10_000
sub.read_timeout = 500.milliseconds
sub.connect("tcp://server:5555")
```

Readable sockets also expose queue-style `dequeue`, `pop`, `wait`, and
`each`; writable sockets expose `enqueue` and `push`.

Use `try_receive` / `try_recv` and `try_send` for nonblocking polling.
They return `nil` or `false` instead of waiting for data or HWM space.

`OMQ.proxy(frontend, backend)` forwards between sockets. Use
`OMQ.proxy_steerable(frontend, backend, control)` for `PAUSE`, `RESUME`,
`TERMINATE`, and `KILL` control commands; an optional capture socket receives
best-effort copies.

`socket.connections` returns live `ConnectionInfo` snapshots. Monitor events
for accepted, connected, and disconnected pipes include the same info.

`socket.wait_connected(min_peers, timeout)` waits for data-plane-ready peers.
PUB/XPUB also expose `wait_subscribed(min_subscriptions, timeout)`.

### Endpoint prefix convention

- `"@tcp://…"`: bind
- `">tcp://…"`: connect
- plain `"tcp://…"`: use the socket-type default (`PUSH`→connect,
  `PULL`→bind, `PUB`→bind, `SUB`→connect, …)

## Options

| Option | Default | Meaning |
|---|---|---|
| `send_hwm` / `recv_hwm` | 1000 | Messages buffered per socket before backpressure/drop kicks in; `0` or explicit `nil` selects the unbounded spelling, mapped internally to a large Crystal channel cap |
| `linger` | `0.seconds` | Close-time drain budget; `nil` = wait forever |
| `identity` | `""` | Peer identity advertised in the ZMTP READY command |
| `read_timeout` / `write_timeout` | `nil` | Raise `IO::TimeoutError` after this span |
| `reconnect_interval` | `100.milliseconds` | Fixed span, or `Range(Time::Span, Time::Span)` for exponential backoff |
| `heartbeat_interval` / `heartbeat_ttl` / `heartbeat_timeout` | `nil` | ZMTP PING/PONG keepalive + silent-peer watchdog |
| `handshake_timeout` | `30.seconds` | Max time for a ZMTP handshake before the transport is closed |
| `max_pending_handshakes` | `1024` | Max accepted TCP/IPC peers allowed to sit in handshake state |
| `max_message_size` | `nil` | Drop the connection if a frame exceeds this many bytes; for `lz4+tcp://` and `zstd+tcp://`, this applies to total decompressed message size |
| `sndbuf` / `rcvbuf` | `nil` | Kernel socket buffer sizes (TCP/IPC only) |
| `dict` / `lz4_dict` | `nil` | Send-side LZ4 dictionary for `lz4+tcp://`; 1-8192 bytes |
| `auto_dict` | `nil` | Enable send-side automatic LZ4 dictionary training for `lz4+tcp://`; `true` uses 2 KiB capacity and 100-message trigger |
| `zstd_level` / `level` | `-3` | Send-side Zstd compression level for `zstd+tcp://` |
| `zstd_dict` | `nil` | Send-side ZDICT dictionary for `zstd+tcp://`; must be a trained ZDICT blob, 1-8192 bytes |
| `zstd_auto_dict` | `nil` | Enable send-side automatic ZDICT training for `zstd+tcp://`; `true` uses 2 KiB capacity and 1000 samples |
| `conflate` | `false` | Keep only the latest queued message where message order carries no envelope state |
| `on_mute` | `:block`; PUB/XPUB use `:drop_newest` | `:block`, `:drop_newest`, `:drop_oldest` |

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

Pre-1.0. All 12 standard socket types work, inproc/ipc/tcp/udp/lz4+tcp/zstd+tcp
all work, heartbeat/linger/reconnect/HWM/on_mute/conflate/max_message_size/sndbuf/rcvbuf
are wired through. PLAIN auth, draft socket types (CLIENT/SERVER,
RADIO/DISH, SCATTER/GATHER, PEER, CHANNEL, STREAM), CURVE encryption (opt-in via
`require "omq/curve"`), and the monitor-event API all work. See
[`CHANGELOG.md`](CHANGELOG.md).

## PLAIN authentication

PLAIN authenticates a username/password during the ZMTP handshake. Traffic
after the handshake is not encrypted.

```crystal
pull = OMQ::PULL.new
pull.mechanism = OMQ::ZMTP::Mechanism::Plain.server({"alice" => "secret"})
pull.bind("tcp://127.0.0.1:5555")

push = OMQ::PUSH.new
push.mechanism = OMQ::ZMTP::Mechanism::Plain.client("alice", "secret")
push.connect("tcp://127.0.0.1:5555")
```

## CURVE encryption

Opt-in; depends on the [`natron`](https://github.com/paddor/natron.cr)
libsodium wrapper. Add it to your shard.yml alongside `omq`, then:

```crystal
require "omq"
require "omq/curve"

server_keys = OMQ::Curve::KeyPair.generate
client_keys = OMQ::Curve::KeyPair.generate

rep = OMQ::REP.new
rep.mechanism = OMQ::ZMTP::Mechanism::Curve.server(
  public_key: server_keys.public_key,
  secret_key: server_keys.secret_key)
rep.bind("tcp://127.0.0.1:5555")

req = OMQ::REQ.new
req.mechanism = OMQ::ZMTP::Mechanism::Curve.client(
  server_key: server_keys.public_z85,
  public_key: client_keys.public_z85,
  secret_key: client_keys.secret_z85)
req.connect("tcp://127.0.0.1:5555")
```

Pass an authenticator proc to the server factory to whitelist client
public keys. Peer authenticators receive `public_key`, `public_z85`,
`identity`, and `peer_address`.

## Development

```sh
shards install
crystal run test/run.cr
```

The full suite runs in ~2 seconds. Add a new test file under
`test/omq/*_test.cr`. `test/run.cr` auto-discovers everything.

## License

[ISC](LICENSE)
