require "../test_helper"

describe "PUB on_mute" do
  it "defaults to drop_newest for slow subscribers" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.new
      pub.send_hwm = 8
      pub.bind("inproc://default-drop-newest")

      sub = OMQ::SUB.connect("inproc://default-drop-newest", subscribe: "")

      OMQ::TestHelper.wait_until { pub.peer_count == 1 && sub.peer_count == 1 }

      total = 2000
      total.times { |i| pub.send("msg-#{i}") }
      Fiber.yield

      sub.read_timeout = 50.milliseconds
      received = [] of String
      loop do
        received << String.new(sub.receive[0])
      rescue IO::TimeoutError
        break
      end

      assert received.size < total, "default drop_newest should discard messages; got #{received.size}"
      assert_equal "msg-0", received.first

      pub.close
      sub.close
    end
  end

  it "drop_newest discards when the per-peer queue is full" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.new
      pub.send_hwm = 8
      pub.on_mute = :drop_newest
      pub.bind("inproc://drop-newest")

      sub = OMQ::SUB.new
      sub.connect("inproc://drop-newest")
      sub.subscribe("")

      OMQ::TestHelper.wait_until { pub.peer_count == 1 && sub.peer_count == 1 }

      # Fire far more than the HWM into a subscriber that isn't reading.
      1000.times { |i| pub.send("msg-#{i}") }

      # Let the dispatcher drain into the per-peer DropQueue.
      Fiber.yield

      sub.read_timeout = 50.milliseconds
      received = [] of String
      loop do
        received << String.new(sub.receive[0])
      rescue IO::TimeoutError
        break
      end

      assert received.size < 1000, "drop_newest should discard most messages; got #{received.size}"
      # drop_newest keeps the earliest messages — the first one must be msg-0.
      assert_equal "msg-0", received.first

      pub.close
      sub.close
    end
  end

  it "drop_oldest evicts the head to keep the newest" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.new
      pub.send_hwm = 8
      pub.on_mute = :drop_oldest
      pub.bind("inproc://drop-oldest")

      sub = OMQ::SUB.new
      sub.connect("inproc://drop-oldest")
      sub.subscribe("")

      OMQ::TestHelper.wait_until { pub.peer_count == 1 && sub.peer_count == 1 }

      1000.times { |i| pub.send("msg-#{i}") }

      Fiber.yield

      sub.read_timeout = 50.milliseconds
      received = [] of String
      loop do
        received << String.new(sub.receive[0])
      rescue IO::TimeoutError
        break
      end

      assert received.size < 1000, "drop_oldest should discard old messages; got #{received.size}"
      # drop_oldest keeps the newest — the final message must be msg-999.
      assert_equal "msg-999", received.last

      pub.close
      sub.close
    end
  end

  it "block override backpressures the publisher" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.new
      pub.on_mute = :block
      pub.bind("inproc://block-mute")
      sub = OMQ::SUB.new
      sub.connect("inproc://block-mute")
      sub.subscribe("")

      OMQ::TestHelper.wait_until { pub.peer_count == 1 && sub.peer_count == 1 }

      20.times { |i| pub.send("msg-#{i}") }

      sub.read_timeout = 100.milliseconds
      received = [] of String
      loop do
        received << String.new(sub.receive[0])
      rescue IO::TimeoutError
        break
      end

      assert_equal 20, received.size

      pub.close
      sub.close
    end
  end
end
