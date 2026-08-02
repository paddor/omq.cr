require "../test_helper"

describe "Stress tests" do
  it "handles 10k messages through PUSH/PULL inproc" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      total = 10_000
      pull = OMQ::PULL.bind("inproc://stress-pushpull")
      push = OMQ::PUSH.connect("inproc://stress-pushpull")

      done = Channel(Nil).new
      spawn do
        total.times { |i| push.send("msg-#{i}") }
        done.send(nil)
      end

      total.times { pull.receive }
      done.receive

      push.close
      pull.close
    end
  end

  it "handles 500 REQ/REP round trips over TCP" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      total = 500
      rep = OMQ::REP.bind("tcp://127.0.0.1:0")
      port = rep.port.not_nil!
      req = OMQ::REQ.connect("tcp://127.0.0.1:#{port}")

      done = Channel(Nil).new
      spawn do
        total.times do
          msg = rep.receive
          rep.send(msg)
        end
        done.send(nil)
      end

      total.times do |i|
        req.send("req-#{i}")
        assert_equal "req-#{i}", String.new(req.receive[0])
      end
      done.receive

      req.close
      rep.close
    end
  end

  it "handles concurrent DEALER sends into one ROUTER" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      dealer_count = 5
      per_dealer = 100
      router = OMQ::ROUTER.bind("inproc://stress-router")
      dealers = Array.new(dealer_count) do |i|
        OMQ::DEALER.connect("inproc://stress-router", identity: "dealer-#{i}")
      end

      dealers.each_with_index do |dealer, dealer_id|
        spawn do
          per_dealer.times { |i| dealer.send("msg-#{dealer_id}-#{i}") }
        end
      end

      counts = Hash(String, Int32).new(0)
      (dealer_count * per_dealer).times do
        msg = router.receive
        counts[String.new(msg[0])] += 1
      end

      assert_equal dealer_count, counts.size
      counts.each_value { |count| assert_equal per_dealer, count }

      dealers.each(&.close)
      router.close
    end
  end

  it "fans out PUB messages to multiple subscribers" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      sub_count = 5
      total = 50
      pub = OMQ::PUB.bind("inproc://stress-pubsub")
      subs = Array.new(sub_count) do
        OMQ::SUB.connect("inproc://stress-pubsub", subscribe: "", read_timeout: 1.second)
      end

      until pub.peer_count == sub_count
        Fiber.yield
      end

      total.times { |i| pub.send("msg-#{i}") }
      subs.each do |sub|
        total.times do |i|
          assert_equal "msg-#{i}", String.new(sub.receive[0])
        end
      end

      subs.each(&.close)
      pub.close
    end
  end

  it "handles 1 MiB messages over TCP" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!
      push = OMQ::PUSH.connect("tcp://127.0.0.1:#{port}")
      big = Bytes.new(1024 * 1024, 0x78_u8)

      push.send(big)
      msg = pull.receive

      assert_equal 1, msg.size
      assert_equal big.size, msg[0].size
      assert_equal big, msg[0]

      push.close
      pull.close
    end
  end
end
