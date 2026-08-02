require "../test_helper"

private def ipv6_available? : Bool
  server = TCPServer.new("::1", 0)
  server.close
  true
rescue
  false
end

describe "IPv6" do
  it "REQ/REP works over TCP with ::1" do
    skip "IPv6 not available on this system" unless ipv6_available?

    OMQ::TestHelper.with_timeout(3.seconds) do
      rep = OMQ::REP.bind("tcp://[::1]:0")
      port = rep.port.not_nil!
      req = OMQ::REQ.connect("tcp://[::1]:#{port}")

      req.send("hello ipv6")
      assert_equal "hello ipv6", String.new(rep.receive[0])
      rep.send("world ipv6")
      assert_equal "world ipv6", String.new(req.receive[0])

      req.close
      rep.close
    end
  end

  it "PUSH/PULL works over TCP with ::1" do
    skip "IPv6 not available on this system" unless ipv6_available?

    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("tcp://[::1]:0")
      port = pull.port.not_nil!
      push = OMQ::PUSH.connect("tcp://[::1]:#{port}")

      push.send("ipv6 pipeline")
      assert_equal "ipv6 pipeline", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end

  it "PUB/SUB works over TCP with ::1" do
    skip "IPv6 not available on this system" unless ipv6_available?

    OMQ::TestHelper.with_timeout(3.seconds) do
      pub = OMQ::PUB.bind("tcp://[::1]:0")
      port = pub.port.not_nil!
      sub = OMQ::SUB.connect("tcp://[::1]:#{port}", subscribe: "topic.")
      OMQ::TestHelper.wait_until { pub.peer_count > 0 && sub.peer_count > 0 }

      pub.send("topic.data")
      assert_equal "topic.data", String.new(sub.receive[0])

      sub.close
      pub.close
    end
  end

  it "canonicalizes ephemeral IPv6 TCP binds" do
    skip "IPv6 not available on this system" unless ipv6_available?

    rep = OMQ::REP.bind("tcp://[::1]:0")
    port = rep.port.not_nil!

    assert port > 0
    assert_match(/tcp:\/\/\[::1\]:#{port}/, rep.inspect)
  ensure
    rep.try(&.close)
  end
end
