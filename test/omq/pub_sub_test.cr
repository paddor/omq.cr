require "../test_helper"

private def collect(sub : OMQ::SUB) : Channel(OMQ::Message)
  ch = Channel(OMQ::Message).new(1024)
  spawn do
    while msg = sub.receive?
      begin
        ch.send(msg)
      rescue Channel::ClosedError
        break
      end
    end
    ch.close
  end
  ch
end

describe "PUB/SUB over inproc" do
  it "delivers to a subscriber of the matching prefix" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.bind("inproc://ps-basic")
      sub = OMQ::SUB.new
      sub.subscribe("weather.")
      sub.connect("inproc://ps-basic")
      ch = collect(sub)

      delivered = nil
      20.times do |i|
        pub.send(["weather.ca".to_slice, "sunny #{i}".to_slice])
        select
        when msg = ch.receive
          delivered = msg
          break
        when timeout(20.milliseconds)
        end
      end

      refute_nil delivered
      msg = delivered.not_nil!
      assert_equal "weather.ca", String.new(msg[0])

      sub.close
      pub.close
    end
  end

  it "filters by prefix" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pub = OMQ::PUB.bind("inproc://ps-filter")
      sub = OMQ::SUB.new
      sub.subscribe("A.")
      sub.connect("inproc://ps-filter")
      ch = collect(sub)

      sleep 5.milliseconds

      100.times do
        pub.send(["A.one".to_slice, "payload".to_slice])
        pub.send(["B.one".to_slice, "payload".to_slice])
      end

      matched = 0
      unmatched = 0
      deadline = Time.instant + 500.milliseconds
      while Time.instant < deadline
        select
        when msg = ch.receive
          topic = String.new(msg[0])
          if topic.starts_with?("A.")
            matched += 1
          else
            unmatched += 1
          end
        when timeout(50.milliseconds)
          break if matched > 0
        end
      end

      assert matched > 0
      assert_equal 0, unmatched

      sub.close
      pub.close
    end
  end

  it "empty prefix matches every message" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.bind("inproc://ps-catchall")
      sub = OMQ::SUB.new
      sub.subscribe("")
      sub.connect("inproc://ps-catchall")
      ch = collect(sub)

      sleep 5.milliseconds

      got_any = false
      30.times do
        pub.send("anything")
        select
        when msg = ch.receive
          refute_nil msg
          got_any = true
          break
        when timeout(20.milliseconds)
        end
      end

      assert got_any

      sub.close
      pub.close
    end
  end
end

describe "PUB/SUB over TCP" do
  it "filters by prefix across TCP" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pub = OMQ::PUB.bind("tcp://127.0.0.1:0")
      port = pub.port.not_nil!
      sub = OMQ::SUB.new
      sub.subscribe("hot.")
      sub.connect("tcp://127.0.0.1:#{port}")
      ch = collect(sub)

      sleep 30.milliseconds

      50.times do
        pub.send(["hot.news".to_slice, "body".to_slice])
        pub.send(["cold.news".to_slice, "body".to_slice])
      end

      hot = 0
      cold = 0
      deadline = Time.instant + 500.milliseconds
      while Time.instant < deadline
        select
        when msg = ch.receive
          topic = String.new(msg[0])
          if topic.starts_with?("hot.")
            hot += 1
          else
            cold += 1
          end
        when timeout(50.milliseconds)
          break if hot > 0
        end
      end

      assert hot > 0
      assert_equal 0, cold

      sub.close
      pub.close
    end
  end
end

describe "PUB/SUB options" do
  it "PUB defaults to drop_newest on mute" do
    pub = OMQ::PUB.new

    assert_equal OMQ::Options::MuteStrategy::DropNewest, pub.on_mute
  ensure
    pub.try(&.close)
  end

  it "XPUB defaults to drop_newest on mute" do
    xpub = OMQ::XPUB.new

    assert_equal OMQ::Options::MuteStrategy::DropNewest, xpub.on_mute
  ensure
    xpub.try(&.close)
  end

  it "SUB and XSUB default to block on mute" do
    sub = OMQ::SUB.new
    xsub = OMQ::XSUB.new

    assert_equal OMQ::Options::MuteStrategy::Block, sub.on_mute
    assert_equal OMQ::Options::MuteStrategy::Block, xsub.on_mute
  ensure
    sub.try(&.close)
    xsub.try(&.close)
  end

  it "allows explicit PUB on_mute override" do
    pub = OMQ::PUB.new(on_mute: :block)

    assert_equal OMQ::Options::MuteStrategy::Block, pub.on_mute
  ensure
    pub.try(&.close)
  end

  it "set_unbounded works with PUB" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.new(linger: 0.seconds)
      pub.set_unbounded
      pub.bind("inproc://pubsub-unbounded")

      sub = OMQ::SUB.new(linger: 0.seconds)
      sub.set_unbounded
      sub.connect("inproc://pubsub-unbounded")
      sub.subscribe("")

      while pub.peer_count.zero?
        Fiber.yield
      end

      pub.send("hello")

      assert_equal "hello", String.new(sub.receive[0])

      pub.close
      sub.close
    end
  end
end

describe "DropQueue" do
  it "close is idempotent" do
    queue = OMQ::DropQueue(String).new(1, OMQ::Options::MuteStrategy::DropNewest)

    queue.close
    queue.close

    assert queue.closed?
    assert_nil queue.receive?
  end
end
