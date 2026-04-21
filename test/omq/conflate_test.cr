require "../test_helper"

describe "PUB conflate" do
  it "delivers only the latest message when conflate is enabled" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.new
      pub.conflate = true
      pub.bind("inproc://conflate-pub")

      sub = OMQ::SUB.new
      sub.connect("inproc://conflate-pub")
      sub.subscribe("")

      while pub.peer_count.zero?
        Fiber.yield
      end

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

      while pub.peer_count.zero?
        Fiber.yield
      end

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
