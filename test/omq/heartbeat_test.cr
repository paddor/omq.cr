require "../test_helper"

describe "Heartbeat" do
  it "sends PINGs at heartbeat_interval and peer replies with PONGs (tcp)" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!

      push = OMQ::PUSH.new
      push.heartbeat_interval = 50.milliseconds
      push.connect("tcp://127.0.0.1:#{port}")

      # A single send verifies the pipe is up; heartbeats run in the
      # background. If they were broken, the data path would be fine, so
      # we need to wait out an interval and check that the peer is still
      # here (nothing has torn the pipe down).
      while push.peer_count.zero? || pull.peer_count.zero?
        Fiber.yield
      end
      push.send("x")
      assert_equal "x", String.new(pull.receive[0])

      sleep 300.milliseconds
      assert_equal 1, push.peer_count
      assert_equal 1, pull.peer_count

      push.close
      pull.close
    end
  end

  it "tears down the connection when peer is silent past heartbeat_timeout" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      # Fake peer: a raw TCPServer that completes a full ZMTP 3.1 NULL
      # handshake (greeting + READY), then drains PUSH's PINGs without
      # ever sending a PONG. PUSH's watchdog must tear the pipe down.
      tcp_server = TCPServer.new("127.0.0.1", 0)
      port = tcp_server.local_address.port
      spawn do
        sock = tcp_server.accept?
        next unless sock
        greeting = Bytes.new(64)
        greeting[0] = 0xFF_u8
        greeting[9] = 0x7F_u8
        greeting[10] = 3_u8
        greeting[11] = 1_u8
        "NULL".to_slice.copy_to(greeting + 12)
        sock.write(greeting)
        sock.flush
        peer_greeting = Bytes.new(64)
        sock.read_fully(peer_greeting)
        ready = OMQ::ZMTP::Command.ready("PULL")
        OMQ::ZMTP::Frame.encode(sock, ready, command: true)
        sock.flush
        OMQ::ZMTP::Frame.decode(sock)
        # Drain PUSH's frames (PINGs, etc.) silently until it closes.
        buf = Bytes.new(4096)
        loop do
          n = sock.read(buf) rescue 0
          break if n == 0
        end
      end

      push = OMQ::PUSH.new
      push.heartbeat_interval = 30.milliseconds
      push.heartbeat_timeout = 80.milliseconds
      push.reconnect_interval = 1.hour
      push.connect("tcp://127.0.0.1:#{port}")

      while push.peer_count.zero?
        Fiber.yield
      end

      started = Time.instant
      while push.peer_count > 0
        Fiber.yield
        break if Time.instant - started > 1.second
      end
      assert_equal 0, push.peer_count,
        "expected heartbeat timeout to tear down pipe within 1s"

      push.close
      tcp_server.close
    end
  end
end
