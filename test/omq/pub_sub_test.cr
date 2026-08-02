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
  it "signals when a subscriber joins" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.bind("inproc://ps-subscriber-joined")
      sub = OMQ::SUB.connect("inproc://ps-subscriber-joined", subscribe: "topic")

      pipe = pub.subscriber_joined.receive
      refute pipe.closed?

      sub.close
      pub.close
    end
  end

  it "delivers to a subscriber of the matching prefix" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.bind("inproc://ps-basic")
      sub = OMQ::SUB.new
      sub.subscribe("weather.")
      sub.connect("inproc://ps-basic")

      pub.subscriber_joined.receive

      pub.send(["weather.ca".to_slice, "sunny".to_slice])
      msg = sub.receive
      assert_equal "weather.ca", String.new(msg[0])
      assert_equal "sunny", String.new(msg[1])

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

      pub.subscriber_joined.receive

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

      pub.subscriber_joined.receive

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

  it "fans out to multiple subscribers" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.bind("inproc://ps-fanout")
      subs = Array.new(3) { OMQ::SUB.connect("inproc://ps-fanout", subscribe: "") }

      3.times { pub.subscriber_joined.receive }

      pub.send(["broadcast".to_slice, "payload".to_slice])

      subs.each do |sub|
        assert_equal ["broadcast", "payload"], sub.receive.map { |frame| String.new(frame) }
      end

      subs.each(&.close)
      pub.close
    end
  end

  it "receives from multiple publishers" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub1 = OMQ::PUB.bind("inproc://ps-source-1")
      pub2 = OMQ::PUB.bind("inproc://ps-source-2")
      sub = OMQ::SUB.new(subscribe: "")
      sub.connect("inproc://ps-source-1")
      sub.connect("inproc://ps-source-2")

      pub1.subscriber_joined.receive
      pub2.subscriber_joined.receive

      pub1.send("from-1")
      pub2.send("from-2")

      received = Array.new(2) { String.new(sub.receive[0]) }
      assert_equal ["from-1", "from-2"], received.sort

      sub.close
      pub1.close
      pub2.close
    end
  end
end

describe "PUB/SUB over TCP" do
  it "signals command-form SUBSCRIBE from a TCP subscriber" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pub = OMQ::PUB.bind("tcp://127.0.0.1:0")
      port = pub.port.not_nil!
      sub = OMQ::SUB.connect("tcp://127.0.0.1:#{port}", subscribe: "tcp.")

      pipe = pub.subscriber_joined.receive
      refute pipe.closed?

      sub.close
      pub.close
    end
  end

  it "filters by prefix across TCP" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pub = OMQ::PUB.bind("tcp://127.0.0.1:0")
      port = pub.port.not_nil!
      sub = OMQ::SUB.new
      sub.subscribe("hot.")
      sub.connect("tcp://127.0.0.1:#{port}")
      ch = collect(sub)

      pub.subscriber_joined.receive

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

  it "fans out to multiple subscribers" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pub = OMQ::PUB.bind("tcp://127.0.0.1:0")
      port = pub.port.not_nil!
      subs = Array.new(3) do
        OMQ::SUB.connect("tcp://127.0.0.1:#{port}", subscribe: "", read_timeout: 1.second)
      end

      3.times { pub.subscriber_joined.receive }

      pub.send(["broadcast".to_slice, "payload".to_slice])

      subs.each do |sub|
        assert_equal ["broadcast", "payload"], sub.receive.map { |frame| String.new(frame) }
      end

      subs.each(&.close)
      pub.close
    end
  end
end

describe "PUB/SUB over IPC" do
  it "fans out to multiple subscribers" do
    path = "/tmp/omq-ps-ipc-fanout-#{Process.pid}.sock"
    File.delete(path) if File.exists?(path)

    OMQ::TestHelper.with_timeout(3.seconds) do
      endpoint = "ipc://#{path}"
      pub = OMQ::PUB.bind(endpoint)
      subs = Array.new(3) { OMQ::SUB.connect(endpoint, subscribe: "", read_timeout: 1.second) }

      3.times { pub.subscriber_joined.receive }

      pub.send(["broadcast".to_slice, "payload".to_slice])

      subs.each do |sub|
        assert_equal ["broadcast", "payload"], sub.receive.map { |frame| String.new(frame) }
      end

      subs.each(&.close)
      pub.close
    end
  ensure
    File.delete(path) if path && File.exists?(path)
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

  it "closes subscriber readiness channels on close" do
    pub = OMQ::PUB.new
    xpub = OMQ::XPUB.new

    pub.close
    xpub.close

    assert pub.subscriber_joined.closed?
    assert xpub.subscriber_joined.closed?
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

      pub.subscriber_joined.receive

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

  it "close is safe from multiple fibers" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      queue = OMQ::DropQueue(String).new(1, OMQ::Options::MuteStrategy::DropNewest)
      done = Channel(Exception?).new(20)

      20.times do
        spawn do
          queue.close
          done.send(nil)
        rescue ex
          done.send(ex)
        end
      end

      20.times do
        ex = done.receive
        raise ex if ex
      end
      assert queue.closed?
      assert_nil queue.receive?
    end
  end
end
