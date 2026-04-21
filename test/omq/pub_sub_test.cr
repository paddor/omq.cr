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
