require "../test_helper"

describe "socket constructor options" do
  it "exposes every core option through socket accessors" do
    push = OMQ::PUSH.new
    mechanism = OMQ::ZMTP::Mechanism::Null.new

    push.send_hwm = 10
    push.recv_hwm = 11
    push.linger = nil
    push.identity = "sock-1"
    push.read_timeout = 100.milliseconds
    push.write_timeout = 200.milliseconds
    push.router_mandatory = true
    push.reconnect_interval = 300.milliseconds
    push.heartbeat_interval = 400.milliseconds
    push.heartbeat_ttl = 500.milliseconds
    push.heartbeat_timeout = 600.milliseconds
    push.max_message_size = 42_i64
    push.conflate = true
    push.sndbuf = 1024
    push.rcvbuf = 2048
    push.on_mute = :drop_newest
    push.mechanism = mechanism

    assert_equal 10, push.send_hwm
    assert_equal 11, push.recv_hwm
    assert_nil push.linger
    assert_equal "sock-1", String.new(push.identity)
    assert_equal 100.milliseconds, push.read_timeout
    assert_equal 200.milliseconds, push.write_timeout
    assert push.router_mandatory?
    assert_equal 300.milliseconds, push.reconnect_interval
    assert_equal 400.milliseconds, push.heartbeat_interval
    assert_equal 500.milliseconds, push.heartbeat_ttl
    assert_equal 600.milliseconds, push.heartbeat_timeout
    assert_equal 42_i64, push.max_message_size
    assert push.conflate
    assert_equal 1024, push.sndbuf
    assert_equal 2048, push.rcvbuf
    assert_equal OMQ::Options::MuteStrategy::DropNewest, push.on_mute
    assert_equal mechanism, push.mechanism

    push.recv_timeout = 700.milliseconds
    push.send_timeout = 800.milliseconds

    assert_equal 700.milliseconds, push.recv_timeout
    assert_equal 700.milliseconds, push.read_timeout
    assert_equal 800.milliseconds, push.send_timeout
    assert_equal 800.milliseconds, push.write_timeout
  ensure
    push.try(&.close)
  end

  it "does not expose mutable identity storage" do
    identity = Bytes[119, 111, 114, 107, 101, 114]
    push = OMQ::PUSH.new(identity: identity)

    identity[0] = 'X'.ord.to_u8
    exposed = push.identity
    exposed[1] = 'Y'.ord.to_u8

    assert_equal "worker", String.new(push.identity)
  ensure
    push.try(&.close)
  end

  it "applies core options from .new keyword arguments" do
    push = OMQ::PUSH.new(send_hwm: 7, write_timeout: 25.milliseconds, linger: 0.seconds)

    assert_equal 7, push.send_hwm
    assert_equal 25.milliseconds, push.write_timeout
    assert_equal 25.milliseconds, push.send_timeout
    assert_equal 0.seconds, push.linger
  ensure
    push.try(&.close)
  end

  it "applies core options from .bind and .connect keyword arguments" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://socket-opts-bind", recv_timeout: 500.milliseconds)
      push = OMQ::PUSH.connect("inproc://socket-opts-bind", send_hwm: 3)

      assert_equal 500.milliseconds, pull.recv_timeout
      assert_equal 3, push.send_hwm

      push.send("hello")
      assert_equal "hello", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end
end

describe "socket introspection" do
  it "includes class name and bound endpoints" do
    rep = OMQ::REP.bind("inproc://inspect-test")

    assert_match(/OMQ::REP/, rep.inspect)
    assert_match(/inproc:\/\/inspect-test/, rep.inspect)
  ensure
    rep.try(&.close)
  end

  it "shows canonical TCP port after binding to port 0" do
    pair = OMQ::PAIR.bind("tcp://127.0.0.1:0")
    port = pair.port.not_nil!

    assert_match(/tcp:\/\/127\.0\.0\.1:#{port}/, pair.inspect)
  ensure
    pair.try(&.close)
  end

  it "shows empty bound list before bind/connect" do
    rep = OMQ::REP.new

    assert_match(/bound=\[\]/, rep.inspect)
  ensure
    rep.try(&.close)
  end

  it "exposes the ØMQ alias" do
    assert_equal OMQ::REQ, ØMQ::REQ
    assert_equal OMQ::PUB, ØMQ::PUB
  end

  it "raises ClosedError when binding or connecting after close" do
    push = OMQ::PUSH.new
    push.close

    assert_raises(OMQ::ClosedError) { push.bind("inproc://closed-bind") }
    assert_raises(OMQ::ClosedError) { push.connect("inproc://closed-connect") }
  end
end

describe "SUB constructor subscription" do
  it "applies subscribe: before connecting" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.bind("inproc://socket-opts-subscribe")
      sub = OMQ::SUB.connect(
        "inproc://socket-opts-subscribe",
        subscribe: "news",
        read_timeout: 500.milliseconds,
      )
      until pub.peer_count == 1
        sleep 1.millisecond
      end

      pub.send(["sports".to_slice, "drop".to_slice])
      pub.send(["news.today".to_slice, "keep".to_slice])

      msg = sub.receive
      assert_equal "news.today", String.new(msg[0])
      assert_equal "keep", String.new(msg[1])

      sub.close
      pub.close
    end
  end
end
