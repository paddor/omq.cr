require "../test_helper"

private def free_tcp_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  server.close
  port
end

private def wait_until(span : Time::Span = 2.seconds, &block : -> Bool) : Nil
  deadline = Time.instant + span
  until block.call
    raise "timed out waiting for condition" if Time.instant >= deadline
    sleep 1.millisecond
  end
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

describe "Reconnect after TCP server restart" do
  it "reconnects PAIR" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      server = OMQ::PAIR.bind("tcp://127.0.0.1:0", linger: 0.seconds)
      port = server.port.not_nil!
      client = OMQ::PAIR.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds, reconnect_interval: 20.milliseconds)
      wait_until { client.peer_count > 0 && server.peer_count > 0 }

      client.send("one")
      assert_equal "one", String.new(server.receive[0])

      server.close
      sleep 50.milliseconds
      server2 = OMQ::PAIR.bind("tcp://127.0.0.1:#{port}", linger: 0.seconds)
      wait_until { client.peer_count > 0 && server2.peer_count > 0 }

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
      wait_until { req.peer_count > 0 && rep.peer_count > 0 }

      req.send("ping")
      assert_equal "ping", String.new(rep.receive[0])
      rep.send("pong")
      assert_equal "pong", String.new(req.receive[0])

      rep.close
      sleep 50.milliseconds
      rep2 = OMQ::REP.bind("tcp://127.0.0.1:#{port}", linger: 0.seconds)
      wait_until { req.peer_count > 0 && rep2.peer_count > 0 }

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
      wait_until { dealer.peer_count > 0 && rep.peer_count > 0 }

      dealer.send(["".to_slice, "request".to_slice])
      assert_equal "request", String.new(rep.receive[0])
      rep.send("reply")
      assert_equal "reply", String.new(dealer.receive.last)

      rep.close
      sleep 50.milliseconds
      rep2 = OMQ::REP.bind("tcp://127.0.0.1:#{port}", linger: 0.seconds)
      wait_until { dealer.peer_count > 0 && rep2.peer_count > 0 }

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
      wait_until { sub.peer_count > 0 && pub.peer_count > 0 }

      pub.send("first")
      assert_equal "first", String.new(sub.receive[0])

      pub.close
      sleep 50.milliseconds
      pub2 = OMQ::PUB.bind("tcp://127.0.0.1:#{port}", linger: 0.seconds)
      wait_until { sub.peer_count > 0 && pub2.peer_count > 0 }

      pub2.send("second")
      assert_equal "second", String.new(sub.receive[0])

      sub.close
      pub2.close
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
      wait_until { push.peer_count > 0 && pull1.peer_count > 0 }

      3.times do |i|
        push.send("old-#{i}")
        assert_equal "old-#{i}", String.new(pull1.receive[0])
      end

      pull1.close
      sleep 50.milliseconds
      pull2 = OMQ::PULL.bind("tcp://127.0.0.1:#{port}", linger: 0.seconds, read_timeout: 1.second)
      wait_until { push.peer_count > 0 && pull2.peer_count > 0 }

      5.times { |i| push.send("new-#{i}") }
      received = [] of String
      5.times { received << String.new(pull2.receive[0]) }

      assert_equal (0...5).map { |i| "new-#{i}" }, received

      push.close
      pull2.close
    end
  end
end
