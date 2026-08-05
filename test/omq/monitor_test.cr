require "../test_helper"

describe "Socket#monitor" do
  it "reports the listen/accept/connected lifecycle for inproc" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      a = OMQ::PAIR.new
      events = a.monitor
      a.bind("inproc://mon-lifecycle")

      b = OMQ::PAIR.connect("inproc://mon-lifecycle")

      listening = events.receive
      assert_equal OMQ::MonitorEvent::Kind::Listening, listening.kind
      assert_equal "inproc://mon-lifecycle", listening.endpoint
      assert_nil listening.pipe

      accepted = events.receive
      assert_equal OMQ::MonitorEvent::Kind::Accepted, accepted.kind
      refute_nil accepted.pipe

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

      b = OMQ::PAIR.new
      events = b.monitor
      b.connect("inproc://mon-connected")

      connected = events.receive
      assert_equal OMQ::MonitorEvent::Kind::Connected, connected.kind
      assert_equal "inproc://mon-connected", connected.endpoint
      refute_nil connected.pipe

      a.close
      b.close
    end
  end

  it "reports handshake success on the TCP connecting side" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!

      push = OMQ::PUSH.new
      events = push.monitor
      push.connect("tcp://127.0.0.1:#{port}")

      connected = OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::Connected)
      succeeded = OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::HandshakeSucceeded)

      assert_equal connected.connection.not_nil!.id, succeeded.connection.not_nil!.id
      assert succeeded.peer_address.not_nil!.includes?("127.0.0.1:#{port}")

      push.close
      pull.close
    end
  end

  it "exposes connection snapshots and attaches them to monitor events" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      router = OMQ::ROUTER.new
      events = router.monitor
      router.bind("inproc://mon-conn-info")
      dealer = OMQ::DEALER.connect("inproc://mon-conn-info", identity: "worker-1")

      events.receive # Listening
      accepted = events.receive

      info = accepted.connection.not_nil!
      assert_equal OMQ::MonitorEvent::Kind::Accepted, accepted.kind
      assert_equal "inproc://mon-conn-info", info.endpoint
      assert_equal "ROUTER", info.socket_type
      assert_equal "worker-1", String.new(info.peer_identity)
      assert_equal OMQ::ZMTP::MINOR_VERSION, info.peer_zmtp_minor
      assert_nil info.peer_address
      refute_nil router.connection_info(info.id)
      assert_equal [info.id], router.connections.map(&.id)

      dealer.close
      disconnected = events.receive
      assert_equal OMQ::MonitorEvent::Kind::Disconnected, disconnected.kind
      assert_equal OMQ::DisconnectReason::PeerClosed, disconnected.reason
      assert_equal info.id, disconnected.connection.not_nil!.id
      assert_nil router.connection_info(info.id)

      router.close
    end
  end

  it "emits Disconnected on the inproc bind side when peer closes" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.new
      events = pull.monitor
      pull.bind("inproc://mon-inproc-disconnect")

      push = OMQ::PUSH.connect("inproc://mon-inproc-disconnect")
      events.receive # Listening
      events.receive # Accepted

      push.close
      disconnected = events.receive

      assert_equal OMQ::MonitorEvent::Kind::Disconnected, disconnected.kind
      assert_equal OMQ::DisconnectReason::PeerClosed, disconnected.reason
      assert_equal "inproc://mon-inproc-disconnect", disconnected.endpoint
      assert_equal 0, pull.peer_count

      pull.close
    end
  end

  it "emits Disconnected on the TCP bind side when peer closes" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.new
      events = pull.monitor
      pull.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!

      push = OMQ::PUSH.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds)
      listening = events.receive
      accepted = events.receive

      assert_equal OMQ::MonitorEvent::Kind::Listening, listening.kind
      assert_equal "tcp://127.0.0.1:#{port}", listening.endpoint
      assert_equal OMQ::MonitorEvent::Kind::Accepted, accepted.kind
      assert_equal "tcp://127.0.0.1:#{port}", accepted.endpoint
      assert accepted.peer_address.not_nil!.includes?("127.0.0.1")

      succeeded = events.receive
      assert_equal OMQ::MonitorEvent::Kind::HandshakeSucceeded, succeeded.kind
      assert_equal accepted.connection.not_nil!.id, succeeded.connection.not_nil!.id
      assert succeeded.connection.not_nil!.peer_address.not_nil!.includes?("127.0.0.1")

      push.close
      disconnected = OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::Disconnected)

      assert_equal OMQ::MonitorEvent::Kind::Disconnected, disconnected.kind
      assert_equal OMQ::DisconnectReason::PeerClosed, disconnected.reason
      assert_equal "tcp://127.0.0.1:#{port}", disconnected.endpoint
      assert_equal 0, pull.peer_count

      pull.close
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

  it "reports Handover when identity routing replaces a peer" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      router = OMQ::ROUTER.new
      events = router.monitor
      router.bind("inproc://mon-handover")

      old_dealer = OMQ::DEALER.connect("inproc://mon-handover", identity: "same")
      OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::Accepted)

      new_dealer = OMQ::DEALER.connect("inproc://mon-handover", identity: "same")
      disconnected = OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::Disconnected)

      assert_equal OMQ::DisconnectReason::Handover, disconnected.reason
      assert_equal "same", String.new(disconnected.connection.not_nil!.peer_identity)
      assert_equal 1, router.peer_count

      old_dealer.close
      new_dealer.close
      router.close
    end
  end

  it "drops events when the subscriber channel is full" do
    s = OMQ::PAIR.new
    events = s.monitor(1)
    s.bind("inproc://mon-dropped")
    s.bind("inproc://mon-dropped-2")

    first = events.receive
    assert_equal OMQ::MonitorEvent::Kind::Listening, first.kind

    s.close
  end

  it "returns a closed monitor channel after socket close" do
    s = OMQ::PAIR.new
    s.close

    assert s.monitor.closed?
    assert_nil s.monitor.receive?
  end
end
