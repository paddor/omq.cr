require "../test_helper"

describe "Handshake hardening" do
  it "does not let one silent accepted TCP peer block later handshakes" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      server = OMQ::PAIR.bind("tcp://127.0.0.1:0", handshake_timeout: 2.seconds)
      raw = TCPSocket.new("127.0.0.1", server.port.not_nil!)

      client = OMQ::PAIR.connect("tcp://127.0.0.1:#{server.port}")
      assert_equal 1, server.wait_connected(1, 500.milliseconds)
      assert_equal 1, client.wait_connected(1, 500.milliseconds)

      client.send("ok")
      assert_equal "ok", String.new(server.receive[0])

      raw.close
      client.close
      server.close
    end
  end

  it "times out silent handshakes and frees pending slots" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      server = OMQ::PAIR.bind("tcp://127.0.0.1:0", handshake_timeout: 100.milliseconds, max_pending_handshakes: 1)
      events = server.monitor
      raw = TCPSocket.new("127.0.0.1", server.port.not_nil!)

      failed = OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::HandshakeFailed, 1.second)
      assert_match /handshake timed out/, failed.error.not_nil!.message.not_nil!

      client = OMQ::PAIR.connect("tcp://127.0.0.1:#{server.port}")
      assert_equal 1, server.wait_connected(1, 1.second)
      assert_equal 1, client.wait_connected(1, 1.second)

      raw.close
      client.close
      server.close
    end
  end

  it "rejects accepted peers when the pending handshake cap is full" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      server = OMQ::PAIR.bind("tcp://127.0.0.1:0", handshake_timeout: 1.second, max_pending_handshakes: 0)
      events = server.monitor
      raw = TCPSocket.new("127.0.0.1", server.port.not_nil!)

      failed = OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::HandshakeFailed, 1.second)
      assert_equal "max pending handshakes reached", failed.error.not_nil!.message

      assert_equal 0, raw.read(Bytes.new(1))

      raw.close
      server.close
    end
  end
end
