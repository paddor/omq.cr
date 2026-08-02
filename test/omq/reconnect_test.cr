require "../test_helper"

describe "Reconnect" do
  it "connects in the background when peer is absent at connect time (tcp)" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      port = OMQ::TestHelper.free_tcp_port
      push = OMQ::PUSH.new
      push.reconnect_interval = 50.milliseconds
      push.connect("tcp://127.0.0.1:#{port}")

      pull = OMQ::PULL.new
      pull.bind("tcp://127.0.0.1:#{port}")

      OMQ::TestHelper.wait_until { push.peer_count > 0 }

      push.send("hello")
      msg = pull.receive
      assert_equal "hello", String.new(msg[0])

      push.close
      pull.close
    end
  end

  it "keeps retrying while peer is down, connects when it comes up (tcp)" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      port = OMQ::TestHelper.free_tcp_port
      endpoint = "tcp://127.0.0.1:#{port}"

      push = OMQ::PUSH.new
      push.reconnect_interval = 30.milliseconds
      events = push.monitor
      push.connect(endpoint)

      delayed = OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::ConnectDelayed)
      retried = OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::ConnectRetried)
      assert_equal endpoint, delayed.endpoint
      assert_equal endpoint, retried.endpoint
      assert push.peer_count.zero?

      pull = OMQ::PULL.new
      pull.bind(endpoint)

      connected = OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::Connected)
      assert_equal endpoint, connected.endpoint
      OMQ::TestHelper.wait_until { push.peer_count > 0 && pull.peer_count > 0 }
      push.send("connected")
      assert_equal "connected", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end

  it "honors exponential backoff via Range(Time::Span, Time::Span)" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      port = OMQ::TestHelper.free_tcp_port

      push = OMQ::PUSH.new
      push.reconnect_interval = 20.milliseconds..80.milliseconds
      events = push.monitor
      push.connect("tcp://127.0.0.1:#{port}")

      delayed = OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::ConnectDelayed)
      first = OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::ConnectRetried)
      second = OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::ConnectRetried)
      third = OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::ConnectRetried)
      first_gap = first.at - delayed.at
      second_gap = second.at - first.at
      third_gap = third.at - second.at

      assert first_gap >= 15.milliseconds,
        "expected first retry after configured minimum, got #{first_gap.total_milliseconds.round(1)} ms"
      assert second_gap >= 35.milliseconds,
        "expected second retry to back off, got #{second_gap.total_milliseconds.round(1)} ms"
      assert third_gap >= 70.milliseconds,
        "expected third retry to cap near max, got #{third_gap.total_milliseconds.round(1)} ms"

      push.close
    end
  end
end

describe "Reconnect after TCP server restart" do
  it "reconnects PAIR" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      server = OMQ::PAIR.bind("tcp://127.0.0.1:0", linger: 0.seconds)
      port = server.port.not_nil!
      client = OMQ::PAIR.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds, reconnect_interval: 20.milliseconds)
      OMQ::TestHelper.wait_until { client.peer_count > 0 && server.peer_count > 0 }

      client.send("one")
      assert_equal "one", String.new(server.receive[0])

      server.close
      OMQ::TestHelper.wait_disconnected(client)
      server2 = OMQ::TestHelper.restart_bind_tcp(OMQ::PAIR, port)
      OMQ::TestHelper.wait_until { client.peer_count > 0 && server2.peer_count > 0 }

      client.send("two")
      assert_equal "two", String.new(server2.receive[0])

      client.close
      server2.close
    end
  end

  it "reconnects REQ/REP" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      rep = OMQ::REP.bind("tcp://127.0.0.1:0", linger: 0.seconds)
      port = rep.port.not_nil!
      req = OMQ::REQ.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds, reconnect_interval: 20.milliseconds)
      OMQ::TestHelper.wait_until { req.peer_count > 0 && rep.peer_count > 0 }

      req.send("ping")
      assert_equal "ping", String.new(rep.receive[0])
      rep.send("pong")
      assert_equal "pong", String.new(req.receive[0])

      rep.close
      OMQ::TestHelper.wait_disconnected(req)
      rep2 = OMQ::TestHelper.restart_bind_tcp(OMQ::REP, port)
      OMQ::TestHelper.wait_until { req.peer_count > 0 && rep2.peer_count > 0 }

      req.send("ping2")
      assert_equal "ping2", String.new(rep2.receive[0])
      rep2.send("pong2")
      assert_equal "pong2", String.new(req.receive[0])

      req.close
      rep2.close
    end
  end

  it "reconnects DEALER/REP" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      rep = OMQ::REP.bind("tcp://127.0.0.1:0", linger: 0.seconds)
      port = rep.port.not_nil!
      dealer = OMQ::DEALER.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds, reconnect_interval: 20.milliseconds)
      OMQ::TestHelper.wait_until { dealer.peer_count > 0 && rep.peer_count > 0 }

      dealer.send(["".to_slice, "request".to_slice])
      assert_equal "request", String.new(rep.receive[0])
      rep.send("reply")
      assert_equal "reply", String.new(dealer.receive.last)

      rep.close
      OMQ::TestHelper.wait_disconnected(dealer)
      rep2 = OMQ::TestHelper.restart_bind_tcp(OMQ::REP, port)
      OMQ::TestHelper.wait_until { dealer.peer_count > 0 && rep2.peer_count > 0 }

      dealer.send(["".to_slice, "request2".to_slice])
      assert_equal "request2", String.new(rep2.receive[0])
      rep2.send("reply2")
      assert_equal "reply2", String.new(dealer.receive.last)

      dealer.close
      rep2.close
    end
  end

  it "reconnects PUB/SUB" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      pub = OMQ::PUB.bind("tcp://127.0.0.1:0", linger: 0.seconds)
      port = pub.port.not_nil!
      sub = OMQ::SUB.connect(
        "tcp://127.0.0.1:#{port}",
        linger: 0.seconds,
        reconnect_interval: 20.milliseconds,
        read_timeout: 1.second,
        subscribe: "",
      )
      OMQ::TestHelper.wait_until { sub.peer_count > 0 && pub.peer_count > 0 }

      pub.send("first")
      assert_equal "first", String.new(sub.receive[0])

      pub.close
      OMQ::TestHelper.wait_disconnected(sub)
      pub2 = OMQ::TestHelper.restart_bind_tcp(OMQ::PUB, port)
      OMQ::TestHelper.wait_until { sub.peer_count > 0 && pub2.peer_count > 0 }

      pub2.send("second")
      assert_equal "second", String.new(sub.receive[0])

      sub.close
      pub2.close
    end
  end

  it "reconnects PUSH/PULL" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0", linger: 0.seconds)
      port = pull.port.not_nil!
      push = OMQ::PUSH.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds, reconnect_interval: 20.milliseconds)
      OMQ::TestHelper.wait_until { push.peer_count > 0 && pull.peer_count > 0 }

      push.send("first")
      assert_equal "first", String.new(pull.receive[0])

      pull.close
      OMQ::TestHelper.wait_disconnected(push)
      pull2 = OMQ::TestHelper.restart_bind_tcp(OMQ::PULL, port)
      OMQ::TestHelper.wait_until { push.peer_count > 0 && pull2.peer_count > 0 }

      push.send("second")
      assert_equal "second", String.new(pull2.receive[0])

      push.close
      pull2.close
    end
  end

  it "reroutes PUSH sends after low-HWM peer loss" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      pull1 = OMQ::PULL.bind("tcp://127.0.0.1:0", linger: 0.seconds)
      port = pull1.port.not_nil!
      push = OMQ::PUSH.connect(
        "tcp://127.0.0.1:#{port}",
        send_hwm: 1,
        linger: 0.seconds,
        reconnect_interval: 20.milliseconds,
      )
      OMQ::TestHelper.wait_until { push.peer_count > 0 && pull1.peer_count > 0 }

      3.times do |i|
        push.send("old-#{i}")
        assert_equal "old-#{i}", String.new(pull1.receive[0])
      end

      pull1.close
      OMQ::TestHelper.wait_disconnected(push)
      pull2 = OMQ::TestHelper.restart_bind_tcp(OMQ::PULL, port)
      pull2.read_timeout = 1.second
      OMQ::TestHelper.wait_until { push.peer_count > 0 && pull2.peer_count > 0 }

      5.times { |i| push.send("new-#{i}") }
      received = [] of String
      5.times { received << String.new(pull2.receive[0]) }

      assert_equal (0...5).map { |i| "new-#{i}" }, received

      push.close
      pull2.close
    end
  end
end
