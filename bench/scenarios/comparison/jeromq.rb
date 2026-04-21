# frozen_string_literal: true

# PUSH/PULL + REQ/REP throughput on JeroMQ, driven from JRuby via Java interop.
# Counterparts: omq.cr (this repo), pyzmq.py, omq.rb (MRI + Ruby OMQ).
#
# Running JeroMQ under JRuby mirrors how Ruby OMQ runs under MRI: a Ruby
# script invoking the implementation's native API. The JRuby VM hosts
# JeroMQ's JVM threads; the script itself is thin glue.
#
# Usage (requires JRuby and jeromq-0.6.0.jar in the same directory):
#   jruby -J-cp jeromq-0.6.0.jar bench/scenarios/comparison/jeromq.rb

raise "this script requires JRuby (got #{RUBY_ENGINE})" unless RUBY_ENGINE == "jruby"

require "java"
java_import "org.zeromq.ZContext"
java_import "org.zeromq.SocketType"

$stdout.sync = true

SIZES  = [128, 1024]
N      = 1_000_000
WARMUP = 10_000


def bench_push_pull(ctx, size)
  payload = Java::byte[size].new
  Java::java.util.Arrays.fill(payload, "x".ord)

  pull = ctx.createSocket(SocketType::PULL)
  pull.bind("tcp://127.0.0.1:*")
  ep = pull.getLastEndpoint

  push = ctx.createSocket(SocketType::PUSH)
  push.connect(ep)

  producer = Thread.new do
    (WARMUP + N).times { push.send(payload, 0) }
  end

  WARMUP.times { pull.recv(0) }

  t0 = java.lang.System.nanoTime
  N.times { pull.recv(0) }
  elapsed = (java.lang.System.nanoTime - t0) / 1e9

  producer.join
  ctx.destroySocket(push)
  ctx.destroySocket(pull)

  rate = N / elapsed
  mbps = rate * size / 1_000_000.0
  printf "  PUSH/PULL %5dB  %10.1f msg/s  %9.1f MB/s  (%.2fs, n=%d)\n",
         size, rate, mbps, elapsed, N
end


def bench_req_rep(ctx, size)
  payload = Java::byte[size].new
  Java::java.util.Arrays.fill(payload, "x".ord)
  rounds = 100_000

  rep = ctx.createSocket(SocketType::REP)
  rep.bind("tcp://127.0.0.1:*")
  ep = rep.getLastEndpoint

  req = ctx.createSocket(SocketType::REQ)
  req.connect(ep)

  server = Thread.new do
    Thread.current.report_on_exception = false
    loop do
      msg = rep.recv(0)
      break if msg.nil?
      rep.send(msg, 0)
    end
  rescue org.zeromq.ZMQException,
         java.nio.channels.ClosedChannelException,
         java.nio.channels.ClosedSelectorException
    # teardown
  end

  1000.times do
    req.send(payload, 0)
    req.recv(0)
  end

  t0 = java.lang.System.nanoTime
  rounds.times do
    req.send(payload, 0)
    req.recv(0)
  end
  elapsed = (java.lang.System.nanoTime - t0) / 1e9

  ctx.destroySocket(req)
  ctx.destroySocket(rep)

  rate   = rounds / elapsed
  lat_us = elapsed / rounds * 1_000_000
  printf "  REQ/REP   %5dB  %10.1f rtt/s  %8.1f µs/rtt  (%.2fs, n=%d)\n",
         size, rate, lat_us, elapsed, rounds
end


puts "JeroMQ via JRuby #{JRUBY_VERSION} (JVM #{java.lang.System.getProperty('java.version')})"
puts "--- JRuby + JeroMQ (pure Java NIO via Java interop, tcp loopback) ---"

ctx = ZContext.new
begin
  SIZES.each { |s| bench_push_pull(ctx, s) }
  SIZES.each { |s| bench_req_rep(ctx, s) }
ensure
  ctx.close
end
