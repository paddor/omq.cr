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

  it "#unbind stops accepting new inproc connections" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://unbind-inproc")
      pull.unbind("inproc://unbind-inproc")

      assert_raises(OMQ::InvalidEndpoint) do
        OMQ::PUSH.connect("inproc://unbind-inproc")
      end

      pull.close
    end
  end
end
