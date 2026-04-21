require "json"
require "../src/omq"

# Shared scaffolding for per-pattern throughput benchmarks, modeled
# 1:1 on the Ruby OMQ `bench/bench_helper.rb`. Call from a pattern
# script:
#
#   require "../bench_helper"
#   OMQ::BenchHelper.run("PUSH/PULL", dir: __DIR__) do |transport, ep, peers, payload|
#     # build sockets, call measure / measure_roundtrip, return Result
#   end
module OMQ::BenchHelper
  extend self

  # ×4 geometric sweep from 128 B to 32 KiB by default.
  SIZES = (ENV["OMQ_BENCH_SIZES"]? || "128,512,2048,8192,32768")
    .split(",").map(&.to_i)

  # Each cell runs ROUNDS timed rounds, reports the fastest. Transient
  # jitter (GC, scheduler preemption, kernel buffering) only ever slows
  # a burst down, so "fastest" approximates peak sustainable throughput.
  ROUNDS = 1
  ROUND_DURATION = (ENV["OMQ_BENCH_TARGET"]? || "1.0").to_f.seconds

  # Calibration warmup window — long enough that a single scheduler
  # hiccup or GC pause doesn't halve the rate estimate.
  WARMUP_DURATION = 300.milliseconds

  # Lower bound on warmup iterations.
  WARMUP_MIN_ITERS = 1_000

  # Untimed prime burst before calibration: soaks up fiber stack
  # allocation, kernel buffer ramp-up, etc.
  PRIME_ITERS = 5_000

  RESULTS_PATH = File.expand_path("results.jsonl", __DIR__)

  # Per-size timeout. prime + calibration + ROUNDS × 1s ≈ 4-5s; 30s
  # leaves headroom for the slowest cells (TCP 32 KiB under load).
  RUN_TIMEOUT = (ENV["OMQ_BENCH_TIMEOUT"]? || "30").to_i.seconds

  TRANSPORTS = (ENV["OMQ_BENCH_TRANSPORTS"]? || "inproc,ipc,tcp").split(",")

  KERNEL = `uname -r`.strip

  @@run_id : String?

  def run_id : String
    @@run_id ||= ENV["OMQ_BENCH_RUN_ID"]? || Time.local.to_s("%Y-%m-%dT%H:%M:%S")
  end

  struct Result
    getter n : Int64
    getter elapsed : Time::Span
    getter mbps : Float64
    getter msgs_s : Float64

    def initialize(@n : Int64, @elapsed : Time::Span, @mbps : Float64, @msgs_s : Float64)
    end
  end

  def run(label : String, dir : String, peer_counts : Array(Int32) = [1, 3], &block : String, String, Int32, Bytes -> Result)
    peer_counts = ENV["OMQ_BENCH_PEERS"].split(",").map(&.to_i) if ENV["OMQ_BENCH_PEERS"]?
    pattern = File.basename(dir)
    puts "#{label} | OMQ #{OMQ::VERSION} | Crystal #{Crystal::VERSION} | #{KERNEL}"
    puts

    seq = 0

    TRANSPORTS.each do |transport|
      peer_counts.each do |peers|
        header = "#{transport} (#{peers} peer#{"s" if peers > 1})"
        puts "--- #{header} ---"
        completed = 0

        SIZES.each do |size|
          seq += 1
          OMQ::Transport::Inproc.reset! if transport == "inproc"

          ep = endpoint(transport, seq)
          payload = Bytes.new(size, 'x'.ord.to_u8)

          done = Channel(Exception?).new(1)
          result_ch = Channel(Result).new(1)

          spawn do
            begin
              r = block.call(transport, ep, peers, payload)
              result_ch.send(r)
              done.send(nil)
            rescue ex
              done.send(ex)
            end
          end

          select
          when err = done.receive
            raise err.not_nil! if err
            r = result_ch.receive
            append_result(pattern, transport, peers, size, r)
            completed += 1
          when timeout(RUN_TIMEOUT)
            abort "BENCH TIMEOUT: #{header} #{size}B exceeded #{RUN_TIMEOUT.total_seconds.to_i}s"
          end
        end

        abort "BENCH FAILED: #{header} produced no results" if completed == 0
        puts
      end
    end
  end

  def endpoint(transport : String, seq : Int32) : String
    case transport
    when "inproc"
      "inproc://bench-#{seq}"
    when "ipc"
      "ipc://@omq-bench-#{seq}-#{Process.pid}"
    when "tcp"
      "tcp://127.0.0.1:0"
    else
      raise "unknown transport #{transport}"
    end
  end

  # After bind, TCP endpoints carry an OS-assigned port. Rewrite them
  # so `connect(endpoint)` hits the right port.
  def resolve_endpoint(transport : String, ep : String, socket : OMQ::Socket) : String
    if transport == "tcp"
      "tcp://127.0.0.1:#{socket.port}"
    else
      ep
    end
  end

  # Busy-wait until every socket has at least one attached pipe, so
  # the timed section doesn't count handshake latency. Poll cheaply
  # (10µs) since the event loop yields between iterations anyway.
  def wait_connected(*sockets : OMQ::Socket, expected : Int32 = 1, timeout : Time::Span = 5.seconds) : Nil
    deadline = Time.instant + timeout
    loop do
      return if sockets.all? { |s| s.peer_count >= expected }
      raise "wait_connected timed out" if Time.instant > deadline
      sleep 10.microseconds
    end
  end

  # Calibrate `n` so that one timed burst lasts ~ROUND_DURATION. The
  # block transports exactly `k` messages in the same burst shape as
  # the measurement. Doubles a timed burst until it reaches
  # WARMUP_DURATION, then extrapolates. Caller must prime first.
  def estimate_n(target : Time::Span = ROUND_DURATION, warmup : Time::Span = WARMUP_DURATION, &burst : Int64 -> Nil) : Int64
    n = WARMUP_MIN_ITERS.to_i64
    loop do
      elapsed = Time.measure { burst.call(n) }
      if elapsed >= warmup
        rate = n.to_f / elapsed.total_seconds
        estimate = (rate * target.total_seconds).to_i64
        return Math.max(estimate, WARMUP_MIN_ITERS.to_i64)
      end
      n *= 4
    end
  end

  # Runs ROUNDS timed bursts of `n` messages and reports the fastest.
  # `align` rounds `n` to a multiple of the burst shape (e.g. peer
  # count) so per-sender divisions stay even.
  def measure_best_of(payload : Bytes, align : Int32 = 1, &burst : Int64 -> Nil) : Result
    burst.call(PRIME_ITERS.to_i64)
    n = estimate_n(&burst)
    n = Math.max((n // align) * align, align.to_i64)

    best : Time::Span? = nil
    ROUNDS.times do
      elapsed = Time.measure { burst.call(n) }
      best = elapsed if best.nil? || elapsed < best.not_nil!
    end

    report(payload.size, n, best.not_nil!)
  end

  def report(msg_size : Int32, n : Int64, elapsed : Time::Span) : Result
    seconds = elapsed.total_seconds
    mbps = n.to_f * msg_size / seconds / 1_000_000.0
    msgs_s = n.to_f / seconds
    printf "  %6s  %8.1f MB/s  %8.0f msg/s  (%.2fs, n=%d)\n",
      "#{msg_size}B", mbps, msgs_s, seconds, n
    Result.new(n: n, elapsed: elapsed, mbps: mbps, msgs_s: msgs_s)
  end

  private def append_result(pattern : String, transport : String, peers : Int32, msg_size : Int32, r : Result) : Nil
    row = {
      run_id:    run_id,
      pattern:   pattern,
      transport: transport,
      peers:     peers,
      msg_size:  msg_size,
      msg_count: r.n,
      elapsed_s: r.elapsed.total_seconds.round(6),
      mbps:      r.mbps.round(2),
      msgs_s:    r.msgs_s.round(1),
    }
    File.open(RESULTS_PATH, "a") do |f|
      row.to_json(f)
      f.puts
    end
  end
end
