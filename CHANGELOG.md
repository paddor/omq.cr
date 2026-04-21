# Changelog

All notable changes to this project will be documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Initial pure-Crystal port of the Ruby `omq` gem (ZMTP 3.1, no FFI)
- Socket types: `PAIR`, `PUSH` / `PULL`, `REQ` / `REP`, `PUB` / `SUB`,
  `XPUB` / `XSUB`, `DEALER` / `ROUTER`
- Transports: `inproc://` (channel-pair, single-peer Pipe bypass),
  `ipc://` (Unix sockets incl. Linux abstract namespace via `@name`),
  `tcp://` (ephemeral ports via `:0`, `TCP_NODELAY` on)
- ZMTP 3.1 codec: frames, greeting, READY / PING / PONG /
  SUBSCRIBE / CANCEL commands, NULL mechanism
- ZMTP 2.x peers rejected after 11 bytes with `UnsupportedVersion`
- Socket options: `send_hwm`, `recv_hwm`, `linger`, `identity`,
  `read_timeout`, `write_timeout`, `reconnect_interval` (fixed span or
  `Range` for exponential backoff), `heartbeat_interval`,
  `heartbeat_ttl`, `heartbeat_timeout`, `max_message_size`, `sndbuf`,
  `rcvbuf`, `conflate` (PUB), `on_mute` (PUB: `:block`, `:drop_newest`,
  `:drop_oldest`)
- Silent-peer watchdog: PING/PONG activity resets the deadline; silent
  peers are disconnected after `heartbeat_timeout`
- `DropQueue(T)` — bounded per-peer queue with configurable overflow
  policy, used by PUB/XPUB under `:drop_newest` / `:drop_oldest`
- Endpoint-prefix convention (`@…` bind, `>…` connect, plain = type
  default) and `Socket.bind` / `Socket.connect` class helpers
- Benchmark suite under `bench/` (push_pull, req_rep, pub_sub,
  router_dealer, pair) with shared calibration, JSONL output, and
  regression reporter; cross-language comparison harness in
  `bench/scenarios/comparison/`
- `Socket#monitor` — connection-lifecycle channel emitting
  `Listening` / `Accepted` / `Connected` / `Disconnected` /
  `ConnectDelayed` / `ConnectRetried` / `HandshakeFailed` / `Closed`
  events; drop-on-full so a slow subscriber never stalls the socket
- Cross-language interop tests under `test/system/` covering REQ/REP,
  PUSH/PULL, PUB/SUB between Crystal OMQ and Ruby `omq` over TCP
- Draft socket types (opt-in via `require "omq/<name>"`):
  CLIENT / SERVER (RFC 41), RADIO / DISH (RFC 48),
  SCATTER / GATHER (RFC 49), PEER (RFC 51), CHANNEL (RFC 52).
  Group- and routing-ID-based routing; DISH emits wire `JOIN`/`LEAVE`
  commands for libzmq RADIO interop; v0.1 RADIO broadcasts and lets
  DISH filter locally.

### Not yet implemented

- CURVE mechanism (blocked on a Crystal libsodium wrapper)
