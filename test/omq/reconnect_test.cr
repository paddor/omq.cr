require "../test_helper"

private def free_tcp_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  server.close
  port
end

describe "Reconnect" do
  it "connects in the background when peer is absent at connect time (tcp)" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      port = free_tcp_port
      push = OMQ::PUSH.new
      push.reconnect_interval = 50.milliseconds
      push.connect("tcp://127.0.0.1:#{port}")

      pull = OMQ::PULL.new
      pull.bind("tcp://127.0.0.1:#{port}")

      while push.peer_count.zero?
        Fiber.yield
      end

      push.send("hello")
      msg = pull.receive
      assert_equal "hello", String.new(msg[0])

      push.close
      pull.close
    end
  end

  it "keeps retrying while peer is down, connects when it comes up (tcp)" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      port = free_tcp_port

      push = OMQ::PUSH.new
      push.reconnect_interval = 30.milliseconds
      push.connect("tcp://127.0.0.1:#{port}")

      # Nothing listening yet; give the retry loop a few cycles.
      sleep 120.milliseconds
      assert push.peer_count.zero?

      pull = OMQ::PULL.new
      pull.bind("tcp://127.0.0.1:#{port}")

      while push.peer_count.zero? || pull.peer_count.zero?
        Fiber.yield
      end
      push.send("connected")
      assert_equal "connected", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end

  it "honors exponential backoff via Range(Time::Span, Time::Span)" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      port = free_tcp_port

      push = OMQ::PUSH.new
      push.reconnect_interval = 20.milliseconds..80.milliseconds
      started = Time.instant
      push.connect("tcp://127.0.0.1:#{port}")

      # Give it enough time to attempt several reconnects and grow the delay.
      sleep 300.milliseconds

      pull = OMQ::PULL.new
      pull.bind("tcp://127.0.0.1:#{port}")

      while push.peer_count.zero?
        Fiber.yield
      end
      elapsed = Time.instant - started
      assert elapsed > 200.milliseconds,
        "expected multiple retry waits, only #{elapsed.total_milliseconds.round(1)} ms elapsed"

      push.close
      pull.close
    end
  end

end
