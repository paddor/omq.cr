require "../test_helper"

describe "nonblocking API" do
  it "returns nil from try_receive when no message is queued" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://nb-recv")
      push = OMQ::PUSH.connect("inproc://nb-recv")

      assert_nil pull.try_receive
      assert_nil pull.try_recv

      assert push.try_send("hello")

      msg = nil.as(OMQ::Message?)
      OMQ::TestHelper.wait_until { !!(msg = pull.try_receive) }
      assert_equal "hello", String.new(msg.not_nil![0])

      push.close
      pull.close
    end
  end

  it "returns false from try_send when the send queue is full" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      push = OMQ::PUSH.bind("inproc://nb-full", send_hwm: 1)

      assert push.try_send("one")
      refute push.try_send("two")

      push.close
    end
  end

  it "does not block routed try_send helpers" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      router = OMQ::ROUTER.bind("inproc://nb-router")
      dealer = OMQ::DEALER.connect("inproc://nb-router", identity: "dealer-1")

      assert router.try_send(["missing".to_slice, "drop".to_slice])

      dealer.send("ready")
      assert_equal ["dealer-1", "ready"], router.receive.map { |frame| String.new(frame) }

      assert router.try_send_to("dealer-1", "reply")
      reply = nil.as(OMQ::Message?)
      OMQ::TestHelper.wait_until { !!(reply = dealer.try_receive) }
      assert_equal ["", "reply"], reply.not_nil!.map { |frame| String.new(frame) }

      mandatory = OMQ::ROUTER.bind("inproc://nb-router-mandatory", router_mandatory: true)
      assert_raises(OMQ::Error) do
        mandatory.try_send(["missing".to_slice, "drop".to_slice])
      end

      dealer.close
      router.close
      mandatory.close
    end
  end

  it "returns false for PAIR try_send before a peer exists" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      a = OMQ::PAIR.bind("inproc://nb-pair")

      refute a.try_send("early")
      assert_nil a.try_receive

      b = OMQ::PAIR.connect("inproc://nb-pair")
      OMQ::TestHelper.wait_until { a.try_send("late") }

      assert_equal "late", String.new(b.receive[0])

      a.close
      b.close
    end
  end

  it "supports try_send_to on SERVER with advertised identities" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      server = OMQ::SERVER.bind("inproc://nb-server")
      client = OMQ::CLIENT.connect("inproc://nb-server", identity: "client-1")

      assert client.try_send("ping")
      request = server.receive
      assert_equal "client-1", String.new(request[0])
      assert_equal "ping", String.new(request[1])

      assert server.try_send_to("client-1".to_slice, "pong")
      reply = nil.as(OMQ::Message?)
      OMQ::TestHelper.wait_until { !!(reply = client.try_receive) }
      assert_equal "pong", String.new(reply.not_nil![0])

      client.close
      server.close
    end
  end
end
