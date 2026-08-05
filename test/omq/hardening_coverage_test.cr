require "../test_helper"

describe "hardening coverage" do
  it "recovers PUSH/PULL when connect happens before TCP bind" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      port = OMQ::TestHelper.free_tcp_port
      endpoint = "tcp://127.0.0.1:#{port}"
      push = OMQ::PUSH.new(linger: 0.seconds, reconnect_interval: 20.milliseconds)
      push.connect(endpoint)

      pull = OMQ::PULL.bind(endpoint, linger: 0.seconds)
      OMQ::TestHelper.wait_until { push.peer_count > 0 && pull.peer_count > 0 }

      push.send("late-bind")
      assert_equal "late-bind", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end

  it "recovers DEALER identity routing when connect happens before TCP bind" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      port = OMQ::TestHelper.free_tcp_port
      endpoint = "tcp://127.0.0.1:#{port}"
      dealer = OMQ::DEALER.new(
        identity: "worker-a",
        linger: 0.seconds,
        reconnect_interval: 20.milliseconds,
      )
      dealer.connect(endpoint)

      router = OMQ::ROUTER.bind(endpoint, linger: 0.seconds)
      OMQ::TestHelper.wait_until { dealer.peer_count > 0 && router.peer_count > 0 }

      dealer.send("ready")
      request = router.receive
      assert_equal "worker-a", String.new(request[0])
      assert_equal "ready", String.new(request[1])

      router.send(["worker-a".to_slice, "reply".to_slice])
      assert_equal "reply", String.new(dealer.receive[0])

      dealer.close
      router.close
    end
  end

  it "treats hostile parser bytes as normal parse errors" do
    64.times do |i|
      bytes = Bytes.new(i + 1) { |j| ((i * 37 + j * 17) & 0xFF).to_u8 }

      begin
        OMQ::ZMTP::Frame.decode(IO::Memory.new(bytes), max_size: 1024_i64)
      rescue OMQ::ProtocolError | IO::EOFError
      end

      begin
        OMQ::ZMTP::Command.parse(bytes)
      rescue OMQ::ProtocolError | ArgumentError
      end

      begin
        OMQ::ZMTP::Greeting.from_io(IO::Memory.new(bytes))
      rescue OMQ::ProtocolError | OMQ::UnsupportedVersion | IO::EOFError | ArgumentError
      end
    end
  end
end
