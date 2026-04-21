require "../test_helper"

describe "Socket#monitor" do
  it "reports the listen/accept/connected lifecycle for inproc" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      a      = OMQ::PAIR.new
      events = a.monitor
      a.bind("inproc://mon-lifecycle")

      b = OMQ::PAIR.connect("inproc://mon-lifecycle")

      listening = events.receive
      assert_equal OMQ::MonitorEvent::Kind::Listening, listening.kind
      assert_equal "inproc://mon-lifecycle", listening.endpoint

      accepted = events.receive
      assert_equal OMQ::MonitorEvent::Kind::Accepted, accepted.kind

      a.close
      b.close

      closed = events.receive
      assert_equal OMQ::MonitorEvent::Kind::Closed, closed.kind
      assert_nil events.receive?
    end
  end

  it "emits Connected on the connecting side" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      a = OMQ::PAIR.bind("inproc://mon-connected")

      b      = OMQ::PAIR.new
      events = b.monitor
      b.connect("inproc://mon-connected")

      connected = events.receive
      assert_equal OMQ::MonitorEvent::Kind::Connected, connected.kind
      assert_equal "inproc://mon-connected", connected.endpoint

      a.close
      b.close
    end
  end

  it "reports ConnectDelayed when TCP dial fails synchronously" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      s = OMQ::PAIR.new
      s.reconnect_interval = 10.seconds
      events = s.monitor
      s.connect("tcp://127.0.0.1:1")

      delayed = events.receive
      assert_equal OMQ::MonitorEvent::Kind::ConnectDelayed, delayed.kind
      refute_nil delayed.error

      s.close
    end
  end

  it "drops events when the subscriber channel is full" do
    s      = OMQ::PAIR.new
    events = s.monitor(1)
    s.bind("inproc://mon-dropped")
    s.bind("inproc://mon-dropped-2")

    first = events.receive
    assert_equal OMQ::MonitorEvent::Kind::Listening, first.kind

    s.close
  end
end
