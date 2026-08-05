require "../test_helper"

describe "Readiness helpers" do
  it "waits for TCP peers after handshakes complete" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect("tcp://127.0.0.1:#{pull.port}")

      assert_equal 1, pull.wait_connected(1, 1.second)
      assert_equal 1, push.wait_connected(1, 1.second)

      push.close
      pull.close
    end
  end

  it "times out when not enough peers are connected" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      push = OMQ::PUSH.bind("tcp://127.0.0.1:0")

      assert_raises(IO::TimeoutError) do
        push.wait_connected(1, 50.milliseconds)
      end

      push.close
    end
  end

  it "does not count accepted raw TCP peers before ZMTP handshake" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pair = OMQ::PAIR.bind("tcp://127.0.0.1:0")
      raw = TCPSocket.new("127.0.0.1", pair.port.not_nil!)

      assert_raises(IO::TimeoutError) do
        pair.wait_connected(1, 50.milliseconds)
      end

      raw.close
      pair.close
    end
  end

  it "waits for PUB subscriptions without consuming subscriber_joined" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pub = OMQ::PUB.bind("inproc://readiness-pub")
      sub = OMQ::SUB.new

      sub.subscribe("a.")
      sub.connect("inproc://readiness-pub")

      assert_equal 1, pub.wait_subscribed(1, 1.second)
      refute pub.subscriber_joined.receive?.nil?

      sub.subscribe("b.")
      assert_equal 2, pub.wait_subscribed(2, 1.second)

      sub.close
      pub.close
    end
  end

  it "times out waiting for subscriptions" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pub = OMQ::PUB.bind("inproc://readiness-no-subs")

      assert_raises(IO::TimeoutError) do
        pub.wait_subscribed(1, 50.milliseconds)
      end

      pub.close
    end
  end

  it "tracks XPUB subscriptions" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      xpub = OMQ::XPUB.bind("inproc://readiness-xpub")
      xsub = OMQ::XSUB.connect("inproc://readiness-xpub")

      xsub.subscribe("weather")

      assert_equal 1, xpub.wait_subscribed(1, 1.second)

      xsub.close
      xpub.close
    end
  end
end
