# ØMQ - ZeroMQ for Crystal, no C required

[![License: ISC](https://img.shields.io/badge/License-ISC-blue.svg)](LICENSE)
[![Crystal](https://img.shields.io/badge/Crystal-%3E%3D%201.21-000000?logo=crystal&logoColor=white)](https://crystal-lang.org)

> **1.71M msg/s** PUSH/PULL over TCP loopback, two OS processes
>
> **28.1 µs** REQ/REP round-trip over TCP loopback, two OS processes
>
> Intel(R) Core(TM) i7-8700B CPU @ 3.20GHz.
> Crystal 1.21.0 release build, 128-byte payloads. See [`bench/`](bench/)
> to measure your host.

Add `omq` to your `shard.yml` and you're done. No libzmq, no FFI, no system
packages. Just Crystal talking to every other ZeroMQ peer out there.

ØMQ gives your Crystal processes a way to talk to each other and to
anything else speaking ZeroMQ without a broker in the middle. The same
API works whether they live in the same process, on the same machine, or
across the network. Reconnects, queuing, and back-pressure are handled for
you; you write the interesting part.

Sibling projects:
* [OMQ.rb](https://github.com/zeromq/omq.rb)
* [OMQ.rs](https://github.com/paddor/omq.rs)
* [OMQ.ts](https://github.com/paddor/omq.ts)

## Highlights

- **Zero dependencies on C**: no FFI, no libzmq, no extensions. `shards
  install` just works everywhere Crystal runs
- **Fast**: Crystal-native `Channel` queues, direct-pipe inproc bypass,
  `TCP_NODELAY` on connect, work-stealing send pumps
- **No context object**: sockets are standalone; the Crystal runtime's
  fiber scheduler is the "context"
- **Every standard socket type**: REQ/REP, PUB/SUB, XPUB/XSUB, PUSH/PULL,
  DEALER/ROUTER, PAIR
- **Draft socket types**: CLIENT/SERVER, RADIO/DISH, SCATTER/GATHER, PEER,
  CHANNEL, STREAM
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

### Pub / Sub over TCP

```crystal
pub = OMQ::PUB.bind("tcp://127.0.0.1:0")
sub = OMQ::SUB.connect("tcp://127.0.0.1:#{pub.port}", subscribe: "")

pub.subscriber_joined.receive
pub.send("news flash")
pp sub.receive.map { |p| String.new(p) }
# => ["news flash"]

sub.close
pub.close
```

### Push / Pull (pipeline)

```crystal
pull = OMQ::PULL.bind("inproc://work")
push = OMQ::PUSH.connect("inproc://work")

push.send("work item")
pp pull.receive.map { |p| String.new(p) }
# => ["work item"]

push.close
pull.close
```

### Compression Transports

Use `lz4+tcp://` or `zstd+tcp://` when payloads have repeated structure
and bandwidth matters. Handshake and ZMTP commands stay raw. Data frames
use the Ruby `omq-lz4` or `omq-zstd` wire envelopes.

```crystal
pull = OMQ::PULL.bind("zstd+tcp://127.0.0.1:0")
push = OMQ::PUSH.connect(
  "zstd+tcp://127.0.0.1:#{pull.port}",
  zstd_auto_dict: true)

push.send("hello, compressed world")
pp pull.receive

push.close
pull.close
```

## License

[ISC](LICENSE)
