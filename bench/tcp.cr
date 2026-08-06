require "../src/omq"

module OMQ::TcpBench
  extend self

  SIZES           = parse_sizes("OMQ_BENCH_SIZES", "128")
  TARGET_SECONDS  = (ENV["OMQ_BENCH_SECONDS"]? || "1.0").to_f64
  ROUNDS          = (ENV["OMQ_BENCH_ROUNDS"]? || "3").to_i
  LATENCY_ITERS   = (ENV["OMQ_BENCH_LATENCY_ITERS"]? || "10000").to_i64
  LATENCY_WARMUP  = (ENV["OMQ_BENCH_LATENCY_WARMUP"]? || "1000").to_i64
  MIN_MESSAGES    = (ENV["OMQ_BENCH_MIN_MESSAGES"]? || "1000").to_i64
  MAX_MESSAGES    = (ENV["OMQ_BENCH_MAX_MESSAGES"]? || "1000000").to_i64
  WARMUP_MESSAGES = (ENV["OMQ_BENCH_WARMUP_MESSAGES"]? || "2000").to_i64
  CPU_LABEL       = ENV["OMQ_BENCH_CPU"]? || detect_cpu

  record ThroughputResult,
    elapsed : Time::Span,
    messages : Int64,
    mbps : Float64,
    msgs_s : Float64

  record LatencyResult,
    elapsed : Time::Span,
    iterations : Int64,
    latency_us : Float64,
    msgs_s : Float64

  def parse_sizes(name : String, fallback : String) : Array(Int32)
    (ENV[name]? || fallback).split(",").map(&.strip).reject(&.empty?).map(&.to_i)
  end

  def detect_cpu : String
    model = "unknown CPU"

    if File.exists?("/proc/cpuinfo")
      File.each_line("/proc/cpuinfo") do |line|
        if line.starts_with?("model name")
          model = line.split(":", 2)[1]?.try(&.strip) || model
          break
        end
      end
    end

    model
  end

  def main : Nil
    if ARGV.first? == "--peer"
      run_peer(ARGV[1]? || abort("missing peer role"), ARGV[2..])
      return
    end

    puts "TCP loopback, two OS processes | OMQ #{OMQ::VERSION} | Crystal #{Crystal::VERSION}"
    puts "CPU: #{CPU_LABEL}"
    puts

    SIZES.each do |size|
      throughput = measure_throughput(size)
      report_throughput(size, throughput)
    end

    puts
    SIZES.each do |size|
      latency = run_req_rep(size, LATENCY_ITERS, LATENCY_WARMUP)
      report_latency(size, latency)
    end
  end

  def measure_throughput(size : Int32) : ThroughputResult
    forced = ENV["OMQ_BENCH_MESSAGES"]?
    if forced
      messages = forced.to_i64
    else
      warm = run_push_pull(size, Math.max(WARMUP_MESSAGES, MIN_MESSAGES))
      rate = warm.messages.to_f64 / Math.max(warm.elapsed.total_seconds, 0.001)
      messages = (rate * TARGET_SECONDS).to_i64
      messages = messages.clamp(MIN_MESSAGES, MAX_MESSAGES)
    end

    best : ThroughputResult? = nil
    ROUNDS.times do
      result = run_push_pull(size, messages)
      best = result if best.nil? || result.elapsed < best.not_nil!.elapsed
    end
    best.not_nil!
  end

  def run_push_pull(size : Int32, messages : Int64) : ThroughputResult
    peer = spawn_peer(["pull", messages.to_s])
    endpoint_line = read_line(peer)
    raise "unexpected peer line: #{endpoint_line}" unless endpoint_line.starts_with?("ENDPOINT ")
    endpoint = endpoint_line["ENDPOINT ".size..]

    push = OMQ::PUSH.new
    push.set_unbounded
    push.connect(endpoint)
    wait_until("PUSH connected") { push.peer_count == 1 }
    payload = payload(size)

    elapsed = Time.measure do
      messages.times { push.send(payload) }
      expect_line(peer, "DONE")
    end
    wait_peer(peer)
    push.close
    throughput_result(size, messages, elapsed)
  ensure
    push.try(&.close)
    terminate_peer(peer)
  end

  def run_req_rep(size : Int32, iterations : Int64, warmup : Int64) : LatencyResult
    total = iterations + warmup
    peer = spawn_peer(["rep", total.to_s])
    endpoint_line = read_line(peer)
    raise "unexpected peer line: #{endpoint_line}" unless endpoint_line.starts_with?("ENDPOINT ")
    endpoint = endpoint_line["ENDPOINT ".size..]

    req = OMQ::REQ.new
    req.set_unbounded
    req.connect(endpoint)
    wait_until("REQ connected") { req.peer_count == 1 }
    payload = payload(size)

    warmup.times do
      req.send(payload)
      req.receive
    end

    elapsed = Time.measure do
      iterations.times do
        req.send(payload)
        req.receive
      end
    end
    expect_line(peer, "DONE")
    wait_peer(peer)
    req.close

    seconds = elapsed.total_seconds
    LatencyResult.new(
      elapsed: elapsed,
      iterations: iterations,
      latency_us: seconds * 1_000_000.0 / iterations.to_f64,
      msgs_s: iterations.to_f64 / seconds
    )
  ensure
    req.try(&.close)
    terminate_peer(peer)
  end

  def run_peer(role : String, args : Array(String)) : Nil
    STDOUT.sync = true

    case role
    when "pull"
      peer_pull(args[0].to_i64)
    when "rep"
      peer_rep(args[0].to_i64)
    else
      abort("unknown peer role #{role}")
    end
  end

  def peer_pull(messages : Int64) : Nil
    pull = OMQ::PULL.new
    pull.set_unbounded
    pull.bind("tcp://127.0.0.1:0")
    puts "ENDPOINT tcp://127.0.0.1:#{pull.port}"

    messages.times { pull.receive }
    pull.close
    puts "DONE"
  ensure
    pull.try(&.close)
  end

  def peer_rep(messages : Int64) : Nil
    rep = OMQ::REP.new
    rep.set_unbounded
    rep.bind("tcp://127.0.0.1:0")
    puts "ENDPOINT tcp://127.0.0.1:#{rep.port}"

    messages.times { rep.send(rep.receive) }
    rep.close
    puts "DONE"
  ensure
    rep.try(&.close)
  end

  def throughput_result(size : Int32, messages : Int64, elapsed : Time::Span) : ThroughputResult
    seconds = elapsed.total_seconds
    ThroughputResult.new(
      elapsed: elapsed,
      messages: messages,
      mbps: messages.to_f64 * size.to_f64 / seconds / 1_000_000.0,
      msgs_s: messages.to_f64 / seconds
    )
  end

  def payload(size : Int32) : Bytes
    Bytes.new(size) { |i| (i & 0xff).to_u8 }
  end

  def wait_until(label : String, timeout : Time::Span = 5.seconds, &block : -> Bool) : Nil
    deadline = Time.instant + timeout
    until block.call
      raise "#{label} timed out" if Time.instant > deadline
      Fiber.yield
    end
  end

  def spawn_peer(args : Array(String)) : Process
    exe = Process.executable_path || PROGRAM_NAME
    Process.new(exe, ["--peer"] + args, input: :pipe, output: :pipe, error: :inherit)
  end

  def read_line(peer : Process) : String
    line = peer.output.gets
    raise "peer closed stdout" if line.nil?
    line
  end

  def expect_line(peer : Process, expected : String) : Nil
    actual = read_line(peer)
    raise "expected peer line #{expected.inspect}, got #{actual.inspect}" unless actual == expected
  end

  def wait_peer(peer : Process) : Nil
    status = peer.wait
    raise "peer exited #{status.exit_code}" unless status.success?
  end

  def terminate_peer(peer : Process?) : Nil
    return unless peer
    return if peer.terminated?
    peer.terminate
    peer.wait
  rescue
  end

  def report_throughput(size : Int32, result : ThroughputResult) : Nil
    printf "PUSH/PULL %6s  %10.0f msg/s  %8.1f MB/s  (%.3fs, n=%d)\n",
      "#{size}B", result.msgs_s, result.mbps,
      result.elapsed.total_seconds, result.messages
  end

  def report_latency(size : Int32, result : LatencyResult) : Nil
    printf "REQ/REP   %6s  %10.2f us RTT  %10.0f msg/s  (%.3fs, n=%d)\n",
      "#{size}B", result.latency_us, result.msgs_s,
      result.elapsed.total_seconds, result.iterations
  end
end

OMQ::TcpBench.main
