require "../test_helper"
require "socket"

describe "Connection error handling" do
  it "server survives client disconnect during TCP handshake" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      rep = OMQ::REP.new(linger: 0.seconds)
      events = rep.monitor
      rep.bind("tcp://127.0.0.1:0")
      port = rep.port.not_nil!

      raw = TCPSocket.new("127.0.0.1", port)
      raw.close
      OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::HandshakeFailed)

      req = OMQ::REQ.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds)
      req.send("after reset")

      assert_equal "after reset", String.new(rep.receive[0])

      req.close
      rep.close
    end
  end

  it "server survives client disconnect during IPC handshake" do
    path = "/tmp/omq-test-epipe-#{Process.pid}.sock"
    File.delete(path) if File.exists?(path)

    OMQ::TestHelper.with_timeout(3.seconds) do
      rep = OMQ::REP.new(linger: 0.seconds)
      events = rep.monitor
      rep.bind("ipc://#{path}")

      raw = UNIXSocket.new(path)
      raw.close
      OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::HandshakeFailed)

      req = OMQ::REQ.connect("ipc://#{path}", linger: 0.seconds)
      req.send("after reset")

      assert_equal "after reset", String.new(rep.receive[0])

      req.close
      rep.close
    end
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "reconnects after an IPC socket file is removed" do
    path = "/tmp/omq-test-reconnect-#{Process.pid}.sock"
    File.delete(path) if File.exists?(path)
    rep2 = nil

    OMQ::TestHelper.with_timeout(5.seconds) do
      rep = OMQ::REP.bind("ipc://#{path}", linger: 0.seconds)
      req = OMQ::REQ.connect(
        "ipc://#{path}",
        linger: 0.seconds,
        reconnect_interval: 20.milliseconds,
      )

      req.send("hello")
      assert_equal "hello", String.new(rep.receive[0])
      rep.send("world")
      assert_equal "world", String.new(req.receive[0])

      rep.close
      OMQ::TestHelper.wait_disconnected(req)

      rep2 = OMQ::REP.bind("ipc://#{path}", linger: 0.seconds)
      OMQ::TestHelper.wait_until { req.peer_count > 0 && rep2.not_nil!.peer_count > 0 }

      req.send("reconnected")
      assert_equal "reconnected", String.new(rep2.not_nil!.receive[0])

      req.close
      rep2.not_nil!.close
    end
  ensure
    rep2.try(&.close)
    File.delete(path) if path && File.exists?(path)
  end
end
