require "../test_helper"

describe "PUSH/PULL over inproc" do
  it "delivers a single message" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://pp-basic")
      push = OMQ::PUSH.connect("inproc://pp-basic")

      push.send("hello")
      got = pull.receive
      assert_equal 1, got.size
      assert_equal "hello", String.new(got[0])

      push.close
      pull.close
    end
  end

  it "round-robins across multiple PULL peers" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      push = OMQ::PUSH.bind("inproc://pp-fanout")

      pulls = Array.new(3) do
        p = OMQ::PULL.new
        p.connect("inproc://pp-fanout")
        p
      end

      total = 60
      collector = Channel(String).new(total)
      pulls.each do |p|
        spawn do
          loop do
            msg = p.receive?
            break unless msg
            collector.send(String.new(msg[0]))
          end
        end
      end

      total.times { |i| push.send("msg-#{i}") }

      received = [] of String
      total.times { received << collector.receive }
      assert_equal total, received.size
      assert_equal total, received.uniq.size

      push.close
      pulls.each(&.close)
    end
  end

  it "delivers two rounds to each PULL peer" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      push = OMQ::PUSH.bind("inproc://pp-round-robin")

      pulls = Array.new(5) do
        pull = OMQ::PULL.connect("inproc://pp-round-robin")
        pull.read_timeout = 500.milliseconds
        pull
      end
      OMQ::TestHelper.wait_until { push.peer_count == pulls.size }

      pulls.size.times { push.send("ABC") }
      pulls.size.times { push.send("DEF") }

      pulls.each do |pull|
        assert_equal "ABC", String.new(pull.receive[0])
        assert_equal "DEF", String.new(pull.receive[0])
      end

      push.close
      pulls.each(&.close)
    end
  end

  it "weights duplicate connects as separate round-robin pipes" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      pull_a = OMQ::PULL.bind("inproc://pp-weight-a")
      pull_b = OMQ::PULL.bind("inproc://pp-weight-b")
      push = OMQ::PUSH.new

      push.connect("inproc://pp-weight-a")
      push.connect("inproc://pp-weight-a")
      push.connect("inproc://pp-weight-b")
      OMQ::TestHelper.wait_until { pull_a.peer_count == 2 && pull_b.peer_count == 1 && push.peer_count == 3 }

      90.times { |i| push.send("weighted-#{i}") }

      count_a = 0
      count_b = 0
      drain_done = Channel(Nil).new(2)

      spawn do
        60.times { pull_a.receive; count_a += 1 }
        drain_done.send(nil)
      end
      spawn do
        30.times { pull_b.receive; count_b += 1 }
        drain_done.send(nil)
      end

      2.times { drain_done.receive }
      assert_equal 60, count_a
      assert_equal 30, count_b

      push.close
      pull_a.close
      pull_b.close
    end
  end

  it "keeps sending to fast peers when one peer is full" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      push = OMQ::PUSH.new(send_hwm: 4, recv_hwm: 4, write_timeout: 500.milliseconds)
      push.bind("inproc://pp-slow-peer")

      slow = OMQ::PULL.connect("inproc://pp-slow-peer", recv_hwm: 4)
      fast = OMQ::PULL.connect("inproc://pp-slow-peer")
      OMQ::TestHelper.wait_until { push.peer_count == 2 }

      fast_received = Atomic(Int32).new(0)
      spawn do
        while fast.receive?
          fast_received.add(1)
        end
      end

      100.times { |i| push.send("msg-#{i}") }

      OMQ::TestHelper.wait_until(1.second) { fast_received.get >= 80 }

      push.close
      slow.close
      fast.close
    end
  end

  it "delivers multiframe messages" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://pp-multi")
      push = OMQ::PUSH.connect("inproc://pp-multi")

      push.send(["a".to_slice, "bb".to_slice, "ccc".to_slice])
      got = pull.receive
      assert_equal 3, got.size
      assert_equal "a", String.new(got[0])
      assert_equal "bb", String.new(got[1])
      assert_equal "ccc", String.new(got[2])

      push.close
      pull.close
    end
  end

  it "delivers queued messages when connect happens before bind" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      push = OMQ::PUSH.connect("inproc://pp-connect-before-bind", linger: 1.second)
      push.send("early-1")
      push.send("early-2")

      pull = OMQ::PULL.bind("inproc://pp-connect-before-bind")
      push.send("late")

      assert_equal "early-1", String.new(pull.receive[0])
      assert_equal "early-2", String.new(pull.receive[0])
      assert_equal "late", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end

  it "does not deadlock binding after many pending connects" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pushes = Array.new(80) do |i|
        push = OMQ::PUSH.connect("inproc://pp-many-pending", linger: 1.second)
        push.send("pending-#{i}")
        push
      end

      pull = OMQ::PULL.bind("inproc://pp-many-pending")
      received = [] of String
      80.times { received << String.new(pull.receive[0]) }

      assert_equal 80, received.size
      assert_equal 80, received.uniq.size

      pushes.each(&.close)
      pull.close
    end
  end

  it "set_unbounded works with send-before-receive" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      push = OMQ::PUSH.new(linger: 0.seconds)
      push.set_unbounded
      push.bind("inproc://pp-unbounded")

      pull = OMQ::PULL.new(linger: 0.seconds)
      pull.set_unbounded
      pull.connect("inproc://pp-unbounded")

      push.send("hello")

      assert_equal "hello", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end

  it "unbounded via HWM nil works with send-before-receive" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      push = OMQ::PUSH.new(linger: 0.seconds)
      push.send_hwm = nil
      push.recv_hwm = nil
      push.bind("inproc://pp-nil-hwm")

      pull = OMQ::PULL.new(linger: 0.seconds)
      pull.send_hwm = nil
      pull.recv_hwm = nil
      pull.connect("inproc://pp-nil-hwm")

      push.send("hello")

      assert_equal "hello", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end
end

describe "PUSH/PULL over TCP" do
  it "delivers messages over an ephemeral port" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!
      push = OMQ::PUSH.connect("tcp://127.0.0.1:#{port}")

      10.times { |i| push.send("msg-#{i}") }
      10.times do |i|
        got = pull.receive
        assert_equal "msg-#{i}", String.new(got[0])
      end

      push.close
      pull.close
    end
  end

  it "delivers queued messages when connect happens before bind" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      port = OMQ::TestHelper.free_tcp_port
      endpoint = "tcp://127.0.0.1:#{port}"
      push = OMQ::PUSH.new(linger: 1.second, reconnect_interval: 20.milliseconds)
      events = push.monitor
      push.connect(endpoint)

      OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::ConnectDelayed)
      push.send("early")

      pull = OMQ::PULL.bind(endpoint)
      OMQ::TestHelper.wait_until { push.peer_count > 0 && pull.peer_count > 0 }
      push.send("late")

      assert_equal "early", String.new(pull.receive[0])
      assert_equal "late", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end
end

describe "PUSH/PULL over IPC" do
  it "delivers messages when bind happens before connect" do
    path = "/tmp/omq-pp-ipc-bind-before-connect-#{Process.pid}.sock"
    File.delete(path) if File.exists?(path)

    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("ipc://#{path}")
      push = OMQ::PUSH.connect("ipc://#{path}")
      OMQ::TestHelper.wait_until { push.peer_count > 0 && pull.peer_count > 0 }

      5.times { |i| push.send("msg-#{i}") }
      5.times do |i|
        assert_equal "msg-#{i}", String.new(pull.receive[0])
      end

      push.close
      pull.close
    end
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "delivers queued messages when connect happens before bind" do
    path = "/tmp/omq-pp-ipc-connect-before-bind-#{Process.pid}.sock"
    File.delete(path) if File.exists?(path)

    OMQ::TestHelper.with_timeout(5.seconds) do
      endpoint = "ipc://#{path}"
      push = OMQ::PUSH.new(linger: 1.second, reconnect_interval: 20.milliseconds)
      events = push.monitor
      push.connect(endpoint)

      OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::ConnectDelayed)
      push.send("early")

      pull = OMQ::PULL.bind(endpoint)
      OMQ::TestHelper.wait_until { push.peer_count > 0 && pull.peer_count > 0 }
      push.send("late")

      assert_equal "early", String.new(pull.receive[0])
      assert_equal "late", String.new(pull.receive[0])

      push.close
      pull.close
    end
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end
