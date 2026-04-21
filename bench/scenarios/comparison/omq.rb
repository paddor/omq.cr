# frozen_string_literal: true

# PUSH/PULL + REQ/REP throughput on Ruby OMQ (pure Ruby, async fibers).
# Counterparts: omq.cr (this repo), pyzmq.py, Comparison.java (JeroMQ).
#
# Usage (requires Ruby >= 3.3 and the `omq` gem installed system-wide):
#   ruby --yjit bench/scenarios/comparison/omq.rb

$stdout.sync = true

require "omq"
require "async"

SIZES  = [128, 1024]
N      = 1_000_000
WARMUP = 10_000


def bench_push_pull(size)
  payload = ("x" * size).b.freeze

  Sync do
    pull = OMQ::PULL.new
    uri = pull.bind("tcp://127.0.0.1:0")
    ep  = "tcp://127.0.0.1:#{uri.port}"

    push = OMQ::PUSH.new
    push.connect(ep)

    producer = Async do
      WARMUP.times { push << payload }
      N.times      { push << payload }
    end

    WARMUP.times { pull.receive }

    t0 = Async::Clock.now
    N.times { pull.receive }
    elapsed = Async::Clock.now - t0

    producer.wait
    push.close
    pull.close

    rate = N / elapsed
    mbps = rate * size / 1_000_000.0
    printf "  PUSH/PULL %5dB  %10.1f msg/s  %9.1f MB/s  (%.2fs, n=%d)\n",
           size, rate, mbps, elapsed, N
  end
end


def bench_req_rep(size)
  payload = ("x" * size).b.freeze
  rounds  = 100_000

  Sync do
    rep = OMQ::REP.new
    uri = rep.bind("tcp://127.0.0.1:0")
    ep  = "tcp://127.0.0.1:#{uri.port}"

    req = OMQ::REQ.new
    req.connect(ep)

    server = Async do
      loop do
        msg = rep.receive
        rep << msg.first
      end
    end

    1000.times do
      req << payload
      req.receive
    end

    t0 = Async::Clock.now
    rounds.times do
      req << payload
      req.receive
    end
    elapsed = Async::Clock.now - t0

    server.stop
    req.close
    rep.close

    rate   = rounds / elapsed
    lat_us = elapsed / rounds * 1_000_000
    printf "  REQ/REP   %5dB  %10.1f rtt/s  %8.1f µs/rtt  (%.2fs, n=%d)\n",
           size, rate, lat_us, elapsed, rounds
  end
end


puts "Ruby OMQ #{OMQ::VERSION} | #{RUBY_DESCRIPTION.split(')').first})"
puts "--- MRI + Ruby OMQ (pure Ruby, Async fibers, tcp loopback) ---"
SIZES.each { |s| bench_push_pull(s) }
SIZES.each { |s| bench_req_rep(s) }
