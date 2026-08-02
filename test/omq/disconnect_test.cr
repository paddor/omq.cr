require "../test_helper"

describe "disconnect / unbind" do
  it "#disconnect closes only pipes for that endpoint" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull1 = OMQ::PULL.bind("inproc://disconnect-ep1", read_timeout: 50.milliseconds)
      pull2 = OMQ::PULL.bind("inproc://disconnect-ep2", read_timeout: 50.milliseconds)

      push = OMQ::PUSH.new
      push.connect("inproc://disconnect-ep1")
      push.connect("inproc://disconnect-ep2")

      push.disconnect("inproc://disconnect-ep1")

      10.times { |i| push.send("post-#{i}") }
      received = [] of String
      10.times { received << String.new(pull2.receive[0]) }

      assert_equal 10, received.size
      assert_equal (0...10).map { |i| "post-#{i}" }, received.sort
      assert_raises(IO::TimeoutError) { pull1.receive }

      push.close
      pull1.close
      pull2.close
    end
  end

  it "#disconnect emits Disconnected on the monitor queue" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://disconnect-monitor")
      push = OMQ::PUSH.new
      events = push.monitor

      push.connect("inproc://disconnect-monitor")
      assert_equal OMQ::MonitorEvent::Kind::Connected, events.receive.kind

      push.disconnect("inproc://disconnect-monitor")
      disconnected = events.receive
      assert_equal OMQ::MonitorEvent::Kind::Disconnected, disconnected.kind
      assert_equal "inproc://disconnect-monitor", disconnected.endpoint

      push.close
      pull.close
    end
  end

  it "#unbind detaches old inproc connections; new connects wait for rebind" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://unbind-inproc")
      pull.unbind("inproc://unbind-inproc")

      push = OMQ::PUSH.connect("inproc://unbind-inproc")
      push.send("queued")

      rebound = OMQ::PULL.bind("inproc://unbind-inproc")
      assert_equal "queued", String.new(rebound.receive[0])

      push.close
      rebound.close
      pull.close
    end
  end

  it "#unbind closes accepted TCP pipes and removes the canonical endpoint" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!
      push = OMQ::PUSH.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds, reconnect_interval: 1.second)

      until pull.peer_count == 1 && push.peer_count == 1
        sleep 1.millisecond
      end

      pull.unbind("tcp://127.0.0.1:#{port}")
      assert_equal 0, pull.peer_count
      refute_match(/tcp:\/\/127\.0\.0\.1:#{port}/, pull.inspect)

      push.close
      pull.close
    end
  end
end
