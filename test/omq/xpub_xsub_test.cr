require "../test_helper"

describe "XPUB/XSUB" do
  it "broadcasts data messages from XPUB to every connected XSUB" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      xpub = OMQ::XPUB.bind("inproc://xpx-fanout")
      sub1 = OMQ::XSUB.new
      sub2 = OMQ::XSUB.new
      sub1.connect("inproc://xpx-fanout")
      sub2.connect("inproc://xpx-fanout")

      while xpub.peer_count < 2
        Fiber.yield
      end

      xpub.send("hello")

      assert_equal "hello", String.new(sub1.receive[0])
      assert_equal "hello", String.new(sub2.receive[0])

      xpub.close
      sub1.close
      sub2.close
    end
  end

  it "surfaces XSUB subscribe events on XPUB rx with the 0x01 marker" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      xpub = OMQ::XPUB.bind("inproc://xpx-subs")
      xsub = OMQ::XSUB.new
      xsub.connect("inproc://xpx-subs")

      while xpub.peer_count.zero?
        Fiber.yield
      end

      xsub.subscribe("topic")

      event = xpub.receive
      assert_equal 1, event.size
      assert_equal 0x01_u8, event[0][0]
      assert_equal "topic", String.new(event[0][1..])

      xsub.unsubscribe("topic")
      cancel = xpub.receive
      assert_equal 0x00_u8, cancel[0][0]
      assert_equal "topic", String.new(cancel[0][1..])

      xpub.close
      xsub.close
    end
  end

  it "XSUB broadcasts outbound sends to every connected XPUB" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub1 = OMQ::XPUB.bind("inproc://xpx-bcast-1")
      pub2 = OMQ::XPUB.bind("inproc://xpx-bcast-2")
      xsub = OMQ::XSUB.new
      xsub.connect("inproc://xpx-bcast-1")
      xsub.connect("inproc://xpx-bcast-2")

      while pub1.peer_count.zero? || pub2.peer_count.zero?
        Fiber.yield
      end

      xsub.subscribe("a")

      msg1 = pub1.receive
      msg2 = pub2.receive
      assert_equal "a", String.new(msg1[0][1..])
      assert_equal "a", String.new(msg2[0][1..])

      pub1.close
      pub2.close
      xsub.close
    end
  end
end
