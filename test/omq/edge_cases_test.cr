require "../test_helper"

describe "Edge cases" do
  it "delivers an empty string frame" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://edge-empty-message")
      push = OMQ::PUSH.connect("inproc://edge-empty-message")

      push.send("")
      msg = pull.receive

      assert_equal 1, msg.size
      assert_equal "", String.new(msg[0])

      push.close
      pull.close
    end
  end

  it "delivers binary data with every byte value" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://edge-binary-message")
      push = OMQ::PUSH.connect("inproc://edge-binary-message")
      binary = Bytes.new(256) { |i| i.to_u8 }

      push.send(binary)
      msg = pull.receive

      assert_equal 1, msg.size
      assert_equal binary, msg[0]

      push.close
      pull.close
    end
  end

  it "routes a DEALER with a 255-byte identity" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      router = OMQ::ROUTER.bind("inproc://edge-bigid")
      dealer = OMQ::DEALER.connect("inproc://edge-bigid", identity: "x" * 255)

      dealer.send("hello")
      msg = router.receive

      assert_equal "x" * 255, String.new(msg[0])
      assert_equal "hello", String.new(msg[1])

      dealer.close
      router.close
    end
  end

  it "survives rapid inproc connect/disconnect cycles" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("inproc://edge-rapid", read_timeout: 50.milliseconds)

      20.times do |i|
        push = OMQ::PUSH.connect("inproc://edge-rapid", linger: 1.second)
        push.send("msg-#{i}")
        Fiber.yield
        push.close
      end

      received = 0
      loop do
        pull.receive
        received += 1
      rescue IO::TimeoutError
        break
      end

      assert received > 0, "expected at least some messages"
      assert_equal 0, pull.peer_count

      pull.close
    end
  end

  it "survives rapid TCP connect/disconnect cycles" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0", read_timeout: 100.milliseconds)
      port = pull.port.not_nil!

      10.times do |i|
        push = OMQ::PUSH.connect("tcp://127.0.0.1:#{port}", linger: 1.second)
        until push.peer_count == 1
          sleep 1.millisecond
        end
        push.send("msg-#{i}")
        push.close
      end

      received = 0
      loop do
        pull.receive
        received += 1
      rescue IO::TimeoutError
        break
      end

      assert received > 0, "expected at least some messages"
      assert_equal 0, pull.peer_count

      pull.close
    end
  end

  it "raises on duplicate inproc bind" do
    rep1 = OMQ::REP.bind("inproc://edge-dupbind")

    assert_raises(OMQ::InvalidEndpoint) do
      OMQ::REP.bind("inproc://edge-dupbind")
    end
  ensure
    rep1.try(&.close)
  end

  it "raises on duplicate TCP bind" do
    rep1 = OMQ::REP.bind("tcp://127.0.0.1:0")
    port = rep1.port.not_nil!

    assert_raises(IO::Error) do
      OMQ::REP.bind("tcp://127.0.0.1:#{port}")
    end
  ensure
    rep1.try(&.close)
  end

  it "close is idempotent across stable sockets" do
    sockets = [
      OMQ::PAIR.new,
      OMQ::PUSH.new,
      OMQ::PULL.new,
      OMQ::REQ.new,
      OMQ::REP.new,
      OMQ::DEALER.new,
      OMQ::ROUTER.new,
      OMQ::PUB.new,
      OMQ::SUB.new,
      OMQ::XPUB.new,
      OMQ::XSUB.new,
    ]

    sockets.each do |socket|
      socket.close
      socket.close
    end
  end
end
