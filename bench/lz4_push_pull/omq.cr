require "json"
require "socket"
require "../../src/omq"

module OMQ::Lz4PushPullBench
  extend self

  SIZES          = parse_sizes("OMQ_BENCH_LZ4_SIZES", "16,64,256,1024,4096,16384,65536,262144")
  TARGET_SECONDS = (ENV["OMQ_BENCH_LZ4_TARGET"]? || "2.0").to_f64
  ROUNDS         = (ENV["OMQ_BENCH_LZ4_ROUNDS"]? || "3").to_i
  DICT_CAPACITY  = (ENV["OMQ_BENCH_LZ4_DICT"]? || "2048").to_i
  OUTPUT_PATH    = ENV["OMQ_BENCH_LZ4_OUTPUT"]? ||
                   File.join(ENV["HOME"]? || ".", ".cache", "omq.cr", "lz4-pushpull.jsonl")
  RUN_ID = ENV["OMQ_BENCH_RUN_ID"]? || Time.local.to_s("%Y-%m-%dT%H:%M:%S")

  LEVELS   = %w[DEBUG INFO WARN ERROR TRACE]
  SERVICES = %w[
    api-gateway auth-svc order-svc payment-svc notify-svc inventory-svc
    shipping-svc billing-svc search-svc user-svc session-svc analytics-svc
    cache-svc config-svc audit-svc rate-limiter
  ]
  METHODS = %w[GET POST PUT DELETE PATCH HEAD OPTIONS]
  PATHS   = %w[
    /v1/widgets /v1/users /v1/orders /v2/events /v1/health /v1/sessions
    /v1/payments /v2/search /v1/inventory /v1/shipping /v1/analytics /v2/config
  ]
  REGIONS = %w[
    us-east-1 us-west-2 eu-west-1 ap-south-1 eu-central-1 ap-northeast-1
    sa-east-1 ca-central-1
  ]
  STATUSES = [200, 201, 202, 204, 301, 302, 304, 400, 401, 403, 404, 405,
              409, 422, 429, 500, 502, 503, 504]
  MSGS = [
    "request handled successfully",
    "resource created",
    "cache miss, fetched from origin",
    "rate limit approaching threshold",
    "upstream timeout, retrying",
    "authentication token refreshed",
    "database connection pool exhausted",
    "circuit breaker tripped",
    "message queued for async processing",
    "TLS handshake completed",
    "request routed to fallback backend",
    "payload validation passed",
    "idempotency key matched existing result",
    "graceful shutdown initiated",
    "health check passed all probes",
    "retry attempt succeeded after backoff",
  ]

  struct Result
    getter messages : Int64
    getter elapsed : Time::Span
    getter msgs_s : Float64
    getter mbps : Float64
    getter wire_bytes : Int32

    def initialize(@messages : Int64, @elapsed : Time::Span, size : Int32, @wire_bytes : Int32)
      seconds = @elapsed.total_seconds
      @msgs_s = @messages.to_f64 / seconds
      @mbps = @messages.to_f64 * size.to_f64 / seconds / 1_000_000.0
    end
  end

  class XorShift32
    def initialize(@state : UInt32)
    end

    def next : UInt32
      x = @state
      x ^= x << 13
      x ^= x >> 17
      x ^= x << 5
      @state = x
      x
    end
  end

  def parse_sizes(name : String, fallback : String) : Array(Int32)
    (ENV[name]? || fallback).split(",").map(&.strip).reject(&.empty?).map(&.to_i)
  end

  def main : Nil
    if ARGV.first? == "--peer"
      run_peer(ARGV[1]? || abort("missing peer role"), ARGV[2..])
    elsif ARGV.first? == "--wire-size"
      transport = ARGV[1]? || abort("missing transport")
      size = (ARGV[2]? || abort("missing size")).to_i
      dict_path = ARGV[3]?
      puts wire_size(transport, size, dict_path)
    elsif ARGV.first? == "--payload-preview"
      size = (ARGV[1]? || abort("missing size")).to_i
      payload = json_payload_seeded(size, 1_u32)
      STDOUT.write(payload[0, {payload.size, 512}.min])
    else
      run_suite
    end
  end

  def run_suite : Nil
    Dir.mkdir_p(File.dirname(OUTPUT_PATH))
    dict_path = nil

    puts "PUSH/PULL LZ4 process bench | OMQ #{OMQ::VERSION} | Crystal #{Crystal::VERSION}"
    puts "sizes: #{SIZES.join(",")} | target: #{TARGET_SECONDS}s | rounds: #{ROUNDS}"
    puts "results: #{OUTPUT_PATH}"
    puts

    dict = train_lz4_json_dict(DICT_CAPACITY)
    dict_path = File.join(Dir.tempdir, "omq-cr-lz4-dict-#{Process.pid}.bin")
    File.open(dict_path, "w") { |file| file.write(dict) }
    puts "trained dict: #{dict.size} B (capacity #{DICT_CAPACITY})"
    puts

    run_transport("tcp", nil)
    puts
    run_transport("lz4+tcp", nil)
    puts
    run_transport("lz4+tcp", dict_path, label: "lz4+tcp + dict", dict_size: dict.size)
  ensure
    File.delete(dict_path) if dict_path && File.exists?(dict_path)
  end

  def run_transport(transport : String, dict_path : String?, label : String = transport, dict_size : Int32? = nil) : Nil
    puts "--- #{label} ---"
    SIZES.each do |size|
      wire = wire_size(transport, size, dict_path)
      best : Result? = nil
      ROUNDS.times do
        result = run_cell(transport, size, dict_path, wire)
        best = result if best.nil? || result.msgs_s > best.not_nil!.msgs_s
      end
      result = best.not_nil!
      report(label, size, result)
      append_result(label, transport, size, result, dict_size)
    end
  end

  def run_cell(transport : String, size : Int32, dict_path : String?, wire : Int32) : Result
    port = free_tcp_port
    endpoint = "#{transport}://127.0.0.1:#{port}"
    push = nil
    pull = nil
    old_timeout = nil
    push = spawn_peer(["push", endpoint, size.to_s], dict_path)
    expect_line(push, "READY")

    pull = OMQ::PULL.new
    pull.set_unbounded
    pull.connect(endpoint)
    wait_until("pull connected") { pull.peer_count == 1 }

    sleep 500.milliseconds
    drain_warmup(pull)

    count = 0_i64
    interval = recv_timer_check_interval(size)
    remaining = interval
    deadline = Time.instant + TARGET_SECONDS.seconds
    old_timeout = pull.read_timeout
    pull.read_timeout = 5.seconds
    elapsed = Time.measure do
      loop do
        pull.receive
        count += 1
        remaining -= 1
        next unless remaining == 0
        break if Time.instant >= deadline
        remaining = interval
      end
    end

    Result.new(messages: count, elapsed: elapsed, size: size, wire_bytes: wire)
  ensure
    pull.try do |socket|
      socket.read_timeout = old_timeout if old_timeout
      socket.close
    end
    terminate_peer(push)
  end

  def run_peer(role : String, args : Array(String)) : Nil
    STDOUT.sync = true
    STDERR.sync = true
    case role
    when "push"
      peer_push(args[0], args[1].to_i)
    else
      abort("unknown peer role #{role}")
    end
  end

  def peer_push(endpoint : String, size : Int32) : Nil
    dict = ENV["OMQ_BENCH_DICT_FILE"]?.try { |path| File.read(path).to_slice.dup }
    push = OMQ::PUSH.new
    push.set_unbounded
    push.dict = dict if dict && endpoint.starts_with?("lz4+tcp://")
    push.bind(endpoint)
    puts "READY"
    wait_until("push connected") { push.peer_count == 1 }

    payload = bench_payload(size)
    loop do
      push.send(payload)
    end
  rescue OMQ::ClosedError
  ensure
    push.try(&.close)
  end

  def bench_payload(size : Int32) : Bytes
    json_payload_random(size)
  end

  def json_payload_random(target_bytes : Int32) : Bytes
    seed_bytes = Bytes.new(4)
    File.open("/dev/urandom") { |file| file.read_fully(seed_bytes) }
    seed = seed_bytes[0].to_u32 |
           (seed_bytes[1].to_u32 << 8) |
           (seed_bytes[2].to_u32 << 16) |
           (seed_bytes[3].to_u32 << 24)
    json_payload_seeded(target_bytes, seed)
  end

  def json_payload_seeded(target_bytes : Int32, seed : UInt32) : Bytes
    rng = XorShift32.new(seed)
    mem = IO::Memory.new(target_bytes + 512)
    while mem.size < target_bytes
      json_record(mem, rng)
    end
    mem.to_slice[0, target_bytes].dup
  end

  def json_record(io : IO, rng : XorShift32) : Nil
    trace_id = rng.next
    span_id = rng.next
    user_id = rng.next
    r = rng.next.to_i64
    level = LEVELS[(r % LEVELS.size).to_i]
    service = SERVICES[((r >> 4) % SERVICES.size).to_i]
    method = METHODS[((r >> 8) % METHODS.size).to_i]
    path = PATHS[((r >> 12) % PATHS.size).to_i]
    region = REGIONS[((r >> 16) % REGIONS.size).to_i]
    status = STATUSES[((r >> 20) % STATUSES.size).to_i]
    latency = (rng.next % 5000) + 1
    msg = MSGS[(rng.next.to_i64 % MSGS.size).to_i]
    host_id = rng.next

    trace = hex8(trace_id)
    span = hex8(span_id)
    host = hex8(host_id)
    io << %({"ts":"2026-04-27T12:34:56.) << trace << "Z\","
    io << %("level":") << level << "\","
    io << %("service":") << service << "\","
    io << %("trace_id":") << trace << span << "\","
    io << %("span_id":") << span << "\","
    io << %("user_id":"u-) << hex8(user_id) << "\","
    io << %("method":") << method << "\","
    io << %("path":") << path << "/" << trace << "\","
    io << %("status":) << status << ","
    io << %("latency_ms":) << latency << ","
    io << %("region":") << region << "\","
    io << %("host":") << service << "-" << host << ".svc.cluster.local\","
    io << %("msg":") << msg << "\"}\n"
  end

  def json_dict_samples : Array(Bytes)
    sample_sizes = [
      {64, 2},
      {128, 2},
      {256, 4},
      {512, 8},
      {1024, 8},
      {2048, 4},
      {4096, 4},
    ]
    samples = [] of Bytes
    sample_sizes.each do |size, count|
      1.upto(count) do |i|
        samples << json_payload_seeded(size, i.to_u32)
      end
    end
    samples
  end

  def train_lz4_json_dict(capacity : Int32) : Bytes
    trainer = Flint::DictTrainer.new(capacity)
    json_dict_samples.each { |sample| trainer.add_sample(sample) }
    trainer.train
  end

  def wire_size(transport : String, size : Int32, dict_path : String?) : Int32
    return size unless transport == "lz4+tcp"

    payload = bench_payload(size)
    dict = dict_path.try { |path| File.read(path).to_slice.dup }
    codec = dict ? Flint::BlockCodec.new(dict: dict) : Flint::BlockCodec.new
    OMQ::Transport::Lz4Tcp::Codec.encode_part(payload, block_codec: codec).size
  end

  def recv_timer_check_interval(size : Int32) : Int32
    size <= 1024 ? 4096 : 256
  end

  def drain_warmup(pull : OMQ::PULL) : Nil
    old_timeout = pull.read_timeout
    pull.read_timeout = 0.seconds
    deadline = Time.instant + 2.milliseconds
    256.times do
      break if Time.instant >= deadline
      pull.receive
    rescue IO::TimeoutError | OMQ::ClosedError
      break
    end
  ensure
    pull.read_timeout = old_timeout
  end

  def free_tcp_port : Int32
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close
    port
  end

  def wait_until(label : String, timeout : Time::Span = 5.seconds, &block : -> Bool) : Nil
    deadline = Time.instant + timeout
    until block.call
      raise "#{label} timed out" if Time.instant > deadline
      sleep 1.millisecond
    end
  end

  def spawn_peer(args : Array(String), dict_path : String?) : Process
    exe = Process.executable_path || PROGRAM_NAME
    env = {} of String => String
    env["OMQ_BENCH_DICT_FILE"] = dict_path if dict_path
    Process.new(exe, ["--peer"] + args, env: env, input: Process::Redirect::Close,
      output: :pipe, error: :inherit)
  end

  def read_line(peer : Process, timeout : Time::Span = 5.seconds) : String
    ch = Channel(String?).new(1)
    spawn do
      ch.send(peer.output.gets)
    rescue
      ch.send(nil)
    end
    select
    when line = ch.receive
      raise "peer closed stdout" unless line
      line
    when timeout(timeout)
      raise "timed out waiting for peer stdout"
    end
  end

  def expect_line(peer : Process, expected : String) : Nil
    actual = read_line(peer)
    raise "expected peer line #{expected.inspect}, got #{actual.inspect}" unless actual == expected
  end

  def terminate_peer(peer : Process?) : Nil
    return unless peer
    return if peer.terminated?
    peer.terminate
    peer.wait
  rescue
  end

  def hex8(value : UInt32) : String
    value.to_s(16).rjust(8, '0')
  end

  def size_label(size : Int32) : String
    if size >= 1024
      "#{size // 1024} KiB"
    else
      "#{size} B"
    end
  end

  def report(label : String, size : Int32, result : Result) : Nil
    printf "%-15s %7s %10.0f msg/s %9.1f MB/s wire %d (%.3fs, n=%d)\n",
      label, size_label(size), result.msgs_s, result.mbps, result.wire_bytes,
      result.elapsed.total_seconds, result.messages
  end

  def append_result(label : String, transport : String, size : Int32, result : Result, dict_size : Int32?) : Nil
    row = {
      run_id:     RUN_ID,
      impl:       "omq.cr",
      pattern:    dict_size ? "pushpull_lz4_dict" : "pushpull_lz4",
      label:      label,
      transport:  transport,
      processes:  2,
      peers:      1,
      msg_size:   size,
      wire_bytes: result.wire_bytes,
      msg_count:  result.messages,
      elapsed_s:  result.elapsed.total_seconds.round(6),
      mbps:       result.mbps.round(2),
      msgs_s:     result.msgs_s.round(1),
      dict_size:  dict_size,
    }
    File.open(OUTPUT_PATH, "a") do |file|
      row.to_json(file)
      file.puts
    end
  end
end

OMQ::Lz4PushPullBench.main
