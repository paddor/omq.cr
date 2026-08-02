require "json"
require "../../src/omq"

module OMQ::TcpProcessBench
  extend self

  THROUGHPUT_SIZES        = parse_sizes("OMQ_BENCH2_SIZES", "16,64,256,1024,4096,16384")
  LATENCY_SIZES           = parse_sizes("OMQ_BENCH2_LATENCY_SIZES", "16,64,256,1024,4096")
  PUBSUB_PEERS            = parse_sizes("OMQ_BENCH2_PUBSUB_PEERS", "4,16")
  TARGET_SECONDS          = (ENV["OMQ_BENCH2_TARGET"]? || "1.0").to_f64
  ROUNDS                  = (ENV["OMQ_BENCH2_ROUNDS"]? || "1").to_i
  LATENCY_ITERS           = (ENV["OMQ_BENCH2_LATENCY_ITERS"]? || "5000").to_i64
  LATENCY_WARMUP          = (ENV["OMQ_BENCH2_LATENCY_WARMUP"]? || "500").to_i64
  MIN_THROUGHPUT_MESSAGES = (ENV["OMQ_BENCH2_MIN_MESSAGES"]? || "1000").to_i64
  MAX_THROUGHPUT_MESSAGES = (ENV["OMQ_BENCH2_MAX_MESSAGES"]? || "1000000").to_i64
  WARMUP_MESSAGES         = (ENV["OMQ_BENCH2_WARMUP_MESSAGES"]? || "2000").to_i64
  RUN_ID                  = ENV["OMQ_BENCH2_RUN_ID"]? || Time.local.to_s("%Y-%m-%dT%H:%M:%S")
  OUTPUT_PATH             = ENV["OMQ_BENCH2_OUTPUT"]? ||
                            File.join(ENV["HOME"]? || ".", ".cache", "omq", "omq-cr-tcp-process.jsonl")

  def parse_sizes(name : String, fallback : String) : Array(Int32)
    (ENV[name]? || fallback).split(",").map(&.strip).reject(&.empty?).map(&.to_i)
  end

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

  def main : Nil
    if ARGV.first? == "--peer"
      run_peer(ARGV[1]? || abort("missing peer role"), ARGV[2..])
    else
      run_suite
    end
  end

  def run_suite : Nil
    Dir.mkdir_p(File.dirname(OUTPUT_PATH))

    puts "TCP process bench | OMQ #{OMQ::VERSION} | Crystal #{Crystal::VERSION}"
    puts "results: #{OUTPUT_PATH}"
    puts

    THROUGHPUT_SIZES.each do |size|
      result = measure_throughput(size, 2) do |messages|
        run_push_pull(size, messages)
      end
      report_throughput("push_pull", size, 2, result)
      append_throughput("push_pull", size, 2, result)
    end

    PUBSUB_PEERS.each do |peers|
      puts
      THROUGHPUT_SIZES.each do |size|
        result = measure_throughput(size, 1) do |messages|
          run_pub_sub(size, messages, peers)
        end
        report_throughput("pub_sub", size, peers, result)
        append_throughput("pub_sub", size, peers, result)
      end
    end

    puts
    LATENCY_SIZES.each do |size|
      result = run_req_rep(size, LATENCY_ITERS, LATENCY_WARMUP)
      report_latency("req_rep", size, result)
      append_latency("req_rep", size, result)
    end
  end

  def measure_throughput(size : Int32, align : Int32, &block : Int64 -> ThroughputResult) : ThroughputResult
    forced = ENV["OMQ_BENCH2_MESSAGES"]?
    if forced
      messages = align_up(forced.to_i64, align)
    else
      warm_messages = align_up(Math.max(WARMUP_MESSAGES, MIN_THROUGHPUT_MESSAGES), align)
      warm = block.call(warm_messages)
      rate = warm.messages.to_f64 / Math.max(warm.elapsed.total_seconds, 0.001)
      messages = (rate * TARGET_SECONDS).to_i64
      messages = messages.clamp(MIN_THROUGHPUT_MESSAGES, MAX_THROUGHPUT_MESSAGES)
      messages = align_up(messages, align)
    end

    best : ThroughputResult? = nil
    ROUNDS.times do
      result = block.call(messages)
      best = result if best.nil? || result.elapsed < best.not_nil!.elapsed
    end
    best.not_nil!
  end

  def run_push_pull(size : Int32, messages : Int64) : ThroughputResult
    peer = spawn_peer(["push-pull", messages.to_s])
    endpoints = [] of String

    loop do
      line = read_line(peer)
      case line
      when .starts_with?("ENDPOINT ")
        endpoints << line["ENDPOINT ".size..]
      when "READY"
        break
      else
        raise "unexpected peer line: #{line}"
      end
    end
    raise "push-pull peer returned #{endpoints.size} endpoints" unless endpoints.size == 2

    push = OMQ::PUSH.new
    push.set_unbounded
    endpoints.each { |endpoint| push.connect(endpoint) }
    wait_until("push connected to 2 pulls") { push.peer_count == 2 }
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

  def run_pub_sub(size : Int32, messages : Int64, peers : Int32) : ThroughputResult
    pub = OMQ::PUB.new(on_mute: :block)
    pub.set_unbounded
    pub.bind("tcp://127.0.0.1:0")
    endpoint = "tcp://127.0.0.1:#{pub.port}"

    peer = spawn_peer(["pub-sub", endpoint, peers.to_s, messages.to_s])
    expect_line(peer, "READY")
    peers.times { pub.subscriber_joined.receive }

    payload = payload(size)
    elapsed = Time.measure do
      messages.times { pub.send(payload) }
      expect_line(peer, "DONE")
    end
    wait_peer(peer)
    pub.close
    throughput_result(size, messages, elapsed)
  ensure
    pub.try(&.close)
    terminate_peer(peer)
  end

  def run_req_rep(size : Int32, iterations : Int64, warmup : Int64) : LatencyResult
    total = iterations + warmup
    peer = spawn_peer(["req-rep", total.to_s])
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
    when "push-pull"
      peer_push_pull(args[0].to_i64)
    when "pub-sub"
      peer_pub_sub(args[0], args[1].to_i, args[2].to_i64)
    when "req-rep"
      peer_req_rep(args[0].to_i64)
    else
      abort("unknown peer role #{role}")
    end
  end

  def peer_push_pull(messages : Int64) : Nil
    pulls = Array(OMQ::PULL).new(2) do
      pull = OMQ::PULL.new
      pull.set_unbounded
      pull.bind("tcp://127.0.0.1:0")
      puts "ENDPOINT tcp://127.0.0.1:#{pull.port}"
      pull
    end
    puts "READY"

    received = Atomic(Int64).new(0)
    done = Channel(Nil).new(1)
    finished = Atomic(Bool).new(false)

    pulls.each do |pull|
      spawn do
        begin
          loop do
            pull.receive
            if received.add(1) + 1 >= messages
              _, sent = finished.compare_and_set(false, true)
              done.send(nil) if sent
              break
            end
          end
        rescue OMQ::ClosedError
        end
      end
    end

    done.receive
    pulls.each(&.close)
    puts "DONE"
  ensure
    pulls.try(&.each(&.close))
  end

  def peer_pub_sub(endpoint : String, peers : Int32, messages : Int64) : Nil
    subs = Array(OMQ::SUB).new(peers) do
      sub = OMQ::SUB.new
      sub.set_unbounded
      sub.subscribe("")
      sub.connect(endpoint)
      sub
    end
    subs.each { |sub| wait_until("SUB connected") { sub.peer_count == 1 } }
    puts "READY"

    done = Channel(Nil).new(peers)
    subs.each do |sub|
      spawn do
        messages.times { sub.receive }
        done.send(nil)
      end
    end
    peers.times { done.receive }
    subs.each(&.close)
    puts "DONE"
  ensure
    subs.try(&.each(&.close))
  end

  def peer_req_rep(messages : Int64) : Nil
    rep = OMQ::REP.new
    rep.set_unbounded
    rep.bind("tcp://127.0.0.1:0")
    puts "ENDPOINT tcp://127.0.0.1:#{rep.port}"

    messages.times do
      rep.send(rep.receive)
    end
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

  def align_up(value : Int64, align : Int32) : Int64
    align64 = align.to_i64
    ((value + align64 - 1) // align64) * align64
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

  def report_throughput(pattern : String, size : Int32, peers : Int32, result : ThroughputResult) : Nil
    printf "%-10s %2d peer %6s %9.1f MB/s %10.0f msg/s (%.3fs, n=%d)\n",
      pattern, peers, "#{size}B", result.mbps, result.msgs_s,
      result.elapsed.total_seconds, result.messages
  end

  def report_latency(pattern : String, size : Int32, result : LatencyResult) : Nil
    printf "%-10s          %6s %9.2f us %10.0f msg/s (%.3fs, n=%d)\n",
      pattern, "#{size}B", result.latency_us, result.msgs_s,
      result.elapsed.total_seconds, result.iterations
  end

  def append_throughput(pattern : String, size : Int32, peers : Int32, result : ThroughputResult) : Nil
    append_result({
      run_id:    RUN_ID,
      impl:      "omq.cr",
      pattern:   pattern,
      transport: "tcp",
      processes: 2,
      peers:     peers,
      msg_size:  size,
      msg_count: result.messages,
      elapsed_s: result.elapsed.total_seconds.round(6),
      mbps:      result.mbps.round(2),
      msgs_s:    result.msgs_s.round(1),
    })
  end

  def append_latency(pattern : String, size : Int32, result : LatencyResult) : Nil
    append_result({
      run_id:     RUN_ID,
      impl:       "omq.cr",
      pattern:    pattern,
      transport:  "tcp",
      processes:  2,
      peers:      1,
      msg_size:   size,
      iterations: result.iterations,
      elapsed_s:  result.elapsed.total_seconds.round(6),
      latency_us: result.latency_us.round(3),
      msgs_s:     result.msgs_s.round(1),
    })
  end

  def append_result(row) : Nil
    File.open(OUTPUT_PATH, "a") do |file|
      row.to_json(file)
      file.puts
    end
  end
end

OMQ::TcpProcessBench.main
