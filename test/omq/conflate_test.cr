require "../test_helper"

module OMQ::ConflateTestHelper
  extend self

  def collect_latest(socket, latest : String, limit : Int32)
    received = [] of String
    socket.read_timeout = 100.milliseconds
    begin
      while received.size < limit
        msg = socket.receive
        body = msg.last? || Bytes.empty
        value = String.new(body)
        received << value
        break if value == latest
      end
    rescue IO::TimeoutError
    end
    received
  end
end

describe "PUB conflate" do
  it "delivers only the latest message when conflate is enabled" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.new
      pub.conflate = true
      pub.bind("inproc://conflate-pub")

      sub = OMQ::SUB.new
      sub.connect("inproc://conflate-pub")
      sub.subscribe("")

      pub.subscriber_joined.receive

      100.times { |i| pub.send("msg-#{i}") }

      sub.read_timeout = 50.milliseconds
      received = [] of String
      loop do
        received << String.new(sub.receive[0])
      rescue IO::TimeoutError
        break
      end

      assert received.size < 100, "conflate should reduce message count; got #{received.size}"
      assert_equal "msg-99", received.last

      pub.close
      sub.close
    end
  end

  it "delivers all messages when conflate is disabled" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.bind("inproc://no-conflate-pub")
      sub = OMQ::SUB.new
      sub.connect("inproc://no-conflate-pub")
      sub.subscribe("")

      pub.subscriber_joined.receive

      10.times { |i| pub.send("msg-#{i}") }

      sub.read_timeout = 50.milliseconds
      received = [] of String
      loop do
        received << String.new(sub.receive[0])
      rescue IO::TimeoutError
        break
      end

      assert_equal 10, received.size

      pub.close
      sub.close
    end
  end
end

describe "Receive-side conflate" do
  it "keeps only latest PULL message under burst load" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("inproc://conflate-pull", conflate: true)
      push = OMQ::PUSH.connect("inproc://conflate-pull")
      pull.wait_connected(1, 1.second)

      n = 2_000
      latest = "m-#{n - 1}"
      n.times { |i| push.send("m-#{i}") }

      received = OMQ::ConflateTestHelper.collect_latest(pull, latest, n)
      assert received.includes?(latest), "latest missing; got #{received.last?}"
      assert received.size < n, "conflate dropped nothing; got #{received.size}"

      push.close
      pull.close
    end
  end

  it "keeps only latest SUB message after filtering" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pub = OMQ::PUB.bind("inproc://conflate-sub", on_mute: :block)
      sub = OMQ::SUB.new(conflate: true)
      sub.subscribe("topic")
      sub.connect("inproc://conflate-sub")
      pub.wait_subscribed(1, 1.second)

      n = 2_000
      latest = "topic-#{n - 1}"
      n.times do |i|
        pub.send("other-#{i}")
        pub.send("topic-#{i}")
      end

      received = OMQ::ConflateTestHelper.collect_latest(sub, latest, n)
      assert received.includes?(latest), "latest missing; got #{received.last?}"
      assert received.size < n, "conflate dropped nothing; got #{received.size}"

      sub.close
      pub.close
    end
  end

  it "keeps only latest XSUB message" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      xpub = OMQ::XPUB.bind("inproc://conflate-xsub", on_mute: :block)
      xsub = OMQ::XSUB.connect("inproc://conflate-xsub", conflate: true)
      xsub.subscribe("")
      xpub.wait_subscribed(1, 1.second)

      n = 2_000
      latest = "m-#{n - 1}"
      n.times { |i| xpub.send("m-#{i}") }

      received = OMQ::ConflateTestHelper.collect_latest(xsub, latest, n)
      assert received.includes?(latest), "latest missing; got #{received.last?}"
      assert received.size < n, "conflate dropped nothing; got #{received.size}"

      xsub.close
      xpub.close
    end
  end

  it "keeps only latest DISH message for joined groups" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      radio = OMQ::RADIO.bind("inproc://conflate-dish")
      dish = OMQ::DISH.connect("inproc://conflate-dish", conflate: true)
      dish.join("weather")
      radio.subscriber_joined.receive

      n = 2_000
      latest = "m-#{n - 1}"
      n.times do |i|
        radio.publish("sports", "ignored-#{i}")
        radio.publish("weather", "m-#{i}")
      end

      received = OMQ::ConflateTestHelper.collect_latest(dish, latest, n)
      assert received.includes?(latest), "latest missing; got #{received.last?}"
      assert received.size < n, "conflate dropped nothing; got #{received.size}"

      dish.close
      radio.close
    end
  end

  it "keeps only latest GATHER message" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      gather = OMQ::GATHER.bind("inproc://conflate-gather", conflate: true)
      scatter = OMQ::SCATTER.connect("inproc://conflate-gather")
      gather.wait_connected(1, 1.second)

      n = 2_000
      latest = "m-#{n - 1}"
      n.times { |i| scatter.send("m-#{i}") }

      received = OMQ::ConflateTestHelper.collect_latest(gather, latest, n)
      assert received.includes?(latest), "latest missing; got #{received.last?}"
      assert received.size < n, "conflate dropped nothing; got #{received.size}"

      scatter.close
      gather.close
    end
  end

  it "keeps only latest DEALER message" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      dealer = OMQ::DEALER.bind("inproc://conflate-dealer", conflate: true)
      router = OMQ::ROUTER.connect("inproc://conflate-dealer")

      dealer.send("ready")
      identity = router.receive[0]

      n = 2_000
      latest = "m-#{n - 1}"
      n.times { |i| router.send([identity, "m-#{i}".to_slice]) }

      received = OMQ::ConflateTestHelper.collect_latest(dealer, latest, n)
      assert received.includes?(latest), "latest missing; got #{received.last?}"
      assert received.size < n, "conflate dropped nothing; got #{received.size}"

      router.close
      dealer.close
    end
  end
end
