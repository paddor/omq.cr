require "../../test_helper"

describe "OMQ::ZMTP::Command" do
  it "encodes READY with socket type and identity" do
    payload = OMQ::ZMTP::Command.ready("REQ", "alice".to_slice)
    name, body = OMQ::ZMTP::Command.parse(payload)
    assert_equal "READY", name

    props = OMQ::ZMTP::Command.parse_properties(body)
    assert_equal "REQ", String.new(props["Socket-Type"])
    assert_equal "alice", String.new(props["Identity"])
  end

  it "encodes READY with an empty identity" do
    payload = OMQ::ZMTP::Command.ready("PUSH")
    _, body = OMQ::ZMTP::Command.parse(payload)
    props = OMQ::ZMTP::Command.parse_properties(body)
    assert_equal "PUSH", String.new(props["Socket-Type"])
    assert_equal 0, props["Identity"].size
  end

  it "encodes READY with extra properties" do
    extras = {"X-Foo" => "bar".to_slice} of String => Bytes
    payload = OMQ::ZMTP::Command.ready("PUB", Bytes.empty, extras)
    _, body = OMQ::ZMTP::Command.parse(payload)
    props = OMQ::ZMTP::Command.parse_properties(body)
    assert_equal "bar", String.new(props["X-Foo"])
  end

  it "round-trips SUBSCRIBE / CANCEL" do
    sub = OMQ::ZMTP::Command.subscribe("topic".to_slice)
    name, body = OMQ::ZMTP::Command.parse(sub)
    assert_equal "SUBSCRIBE", name
    assert_equal "topic", String.new(body)

    cancel = OMQ::ZMTP::Command.cancel("topic".to_slice)
    name2, _ = OMQ::ZMTP::Command.parse(cancel)
    assert_equal "CANCEL", name2
  end

  it "round-trips JOIN / LEAVE" do
    join = OMQ::ZMTP::Command.join("broadcast")
    name, body = OMQ::ZMTP::Command.parse(join)
    assert_equal "JOIN", name
    assert_equal "broadcast", String.new(body)

    leave = OMQ::ZMTP::Command.leave("broadcast")
    name2, _ = OMQ::ZMTP::Command.parse(leave)
    assert_equal "LEAVE", name2
  end

  it "round-trips PING / PONG with context" do
    payload = OMQ::ZMTP::Command.ping(300_u16, "ctx".to_slice)
    name, body = OMQ::ZMTP::Command.parse(payload)
    assert_equal "PING", name
    ttl, ctx = OMQ::ZMTP::Command.parse_ping(body)
    assert_equal 300_u16, ttl
    assert_equal "ctx", String.new(ctx)

    pong = OMQ::ZMTP::Command.pong("ctx".to_slice)
    pname, pbody = OMQ::ZMTP::Command.parse(pong)
    assert_equal "PONG", pname
    assert_equal "ctx", String.new(pbody)
  end

  it "rejects a truncated command" do
    # name-length byte claims 10, but only 3 bytes of name follow
    assert_raises(OMQ::ProtocolError) { OMQ::ZMTP::Command.parse(Bytes[10, 65, 66, 67]) }
  end
end
