require "../test_helper"

describe "DEALER/ROUTER over inproc" do
  it "round-trips a message with identity prepended on receive" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      router = OMQ::ROUTER.bind("inproc://rd-basic")

      dealer = OMQ::DEALER.new
      dealer.identity = "worker-1".to_slice
      dealer.connect("inproc://rd-basic")

      dealer.send("hello")
      got = router.receive
      assert_equal 2, got.size
      assert_equal "worker-1", String.new(got[0])
      assert_equal "hello",    String.new(got[1])

      # Route a reply back using the identity ROUTER surfaced.
      router.send([got[0], "hi back".to_slice])
      reply = dealer.receive
      assert_equal 1, reply.size
      assert_equal "hi back", String.new(reply[0])

      dealer.close
      router.close
    end
  end

  it "routes between multiple dealers by identity" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      router = OMQ::ROUTER.bind("inproc://rd-multi")

      dealers = ["a", "b", "c"].map do |id|
        d = OMQ::DEALER.new
        d.identity = id.to_slice
        d.connect("inproc://rd-multi")
        d
      end

      # Each dealer announces itself; router reads N messages and
      # replies to each by identity.
      dealers.each_with_index { |d, i| d.send("ping-#{i}") }
      seen = {} of String => String
      3.times do
        req = router.receive
        seen[String.new(req[0])] = String.new(req[1])
      end
      assert_equal({"a" => "ping-0", "b" => "ping-1", "c" => "ping-2"}, seen)

      # Reply to each.
      dealers.each_with_index do |d, i|
        router.send([d.identity, "pong-#{i}".to_slice])
      end
      dealers.each_with_index do |d, i|
        reply = d.receive
        assert_equal "pong-#{i}", String.new(reply[0])
      end

      dealers.each(&.close)
      router.close
    end
  end

  it "silently drops sends to unknown identities" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      router = OMQ::ROUTER.bind("inproc://rd-unknown")
      dealer = OMQ::DEALER.new
      dealer.identity = "known".to_slice
      dealer.connect("inproc://rd-unknown")

      dealer.send("hi")
      router.receive

      # Unknown identity: no error, just dropped.
      router.send(["ghost".to_slice, "whatever".to_slice])

      # Known identity still works.
      router.send(["known".to_slice, "reply".to_slice])
      reply = dealer.receive
      assert_equal "reply", String.new(reply[0])

      dealer.close
      router.close
    end
  end
end


describe "DEALER/ROUTER over TCP" do
  it "round-trips using the ZMTP-advertised identity" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      router = OMQ::ROUTER.bind("tcp://127.0.0.1:0")
      port = router.port.not_nil!

      dealer = OMQ::DEALER.new
      dealer.identity = "tcp-worker".to_slice
      dealer.connect("tcp://127.0.0.1:#{port}")

      dealer.send("hello")
      got = router.receive
      assert_equal 2, got.size
      assert_equal "tcp-worker", String.new(got[0])
      assert_equal "hello",      String.new(got[1])

      router.send([got[0], "hi".to_slice])
      reply = dealer.receive
      assert_equal "hi", String.new(reply[0])

      dealer.close
      router.close
    end
  end
end
