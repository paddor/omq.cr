require "../../../src/omq"

# PUSH/PULL + REQ/REP throughput on this omq.cr (pure Crystal, Crystal
# fibers, tcp loopback). Counterpart scripts live next to this file:
# pyzmq.py (pyzmq → libzmq), jeromq.java (JeroMQ, pure Java), omq.rb
# (Ruby OMQ, pure Ruby). Each prints one line per (pattern, size).
#
# Usage: crystal run --release bench/scenarios/comparison/omq.cr

STDOUT.sync = true

SIZES  = [128, 1024]
N      = 1_000_000
WARMUP = 10_000


def bench_push_pull(size : Int32) : Nil
  payload = Bytes.new(size, 'x'.ord.to_u8)

  pull = OMQ::PULL.new
  pull.bind("tcp://127.0.0.1:0")
  ep = "tcp://127.0.0.1:#{pull.port}"

  push = OMQ::PUSH.new
  push.connect(ep)

  producer_done = Channel(Nil).new(1)
  spawn do
    (WARMUP + N).times { push.send(payload) }
    producer_done.send(nil)
  end

  WARMUP.times { pull.receive }

  t0 = Time.instant
  N.times { pull.receive }
  elapsed = Time.instant - t0

  producer_done.receive
  push.close
  pull.close

  rate = N / elapsed.total_seconds
  mbps = rate * size / 1_000_000.0
  printf "  PUSH/PULL %5dB  %10.1f msg/s  %9.1f MB/s  (%.2fs, n=%d)\n",
    size, rate, mbps, elapsed.total_seconds, N
end


def bench_req_rep(size : Int32) : Nil
  payload = Bytes.new(size, 'x'.ord.to_u8)
  rounds = 100_000

  rep = OMQ::REP.new
  rep.bind("tcp://127.0.0.1:0")
  ep = "tcp://127.0.0.1:#{rep.port}"

  req = OMQ::REQ.new
  req.connect(ep)

  spawn do
    loop do
      msg = rep.receive? || break
      rep.send(msg)
    end
  end

  1000.times do
    req.send(payload)
    req.receive
  end

  t0 = Time.instant
  rounds.times do
    req.send(payload)
    req.receive
  end
  elapsed = Time.instant - t0

  req.close
  rep.close

  rate = rounds / elapsed.total_seconds
  lat_us = elapsed.total_seconds / rounds * 1_000_000
  printf "  REQ/REP   %5dB  %10.1f rtt/s  %8.1f µs/rtt  (%.2fs, n=%d)\n",
    size, rate, lat_us, elapsed.total_seconds, rounds
end


puts "omq.cr #{OMQ::VERSION} | Crystal #{Crystal::VERSION}"
puts "--- Crystal + omq.cr (pure Crystal, fibers, tcp loopback) ---"
SIZES.each { |s| bench_push_pull(s) }
SIZES.each { |s| bench_req_rep(s) }
