require "../test_helper"

describe "Linger" do
  it "drains send queue before closing when linger > 0 (tcp)" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!

      push = OMQ::PUSH.new
      push.linger = 2.seconds
      push.connect("tcp://127.0.0.1:#{port}")

      5.times { |i| push.send("msg-#{i}") }
      push.close

      5.times do |i|
        msg = pull.receive
        assert_equal "msg-#{i}", String.new(msg[0])
      end

      pull.close
    end
  end

  it "closes immediately when linger = 0" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!

      push = OMQ::PUSH.new
      push.linger = 0.seconds
      push.connect("tcp://127.0.0.1:#{port}")

      push.send("before close")

      elapsed = Time.measure { push.close }
      assert elapsed < 100.milliseconds,
        "linger=0 close took #{elapsed.total_milliseconds.round(1)} ms"

      pull.close
    end
  end

  it "delivers all messages before close completes over tcp" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!

      push = OMQ::PUSH.new
      push.linger = 2.seconds
      push.connect("tcp://127.0.0.1:#{port}")
      until push.peer_count > 0 && pull.peer_count > 0
        Fiber.yield
      end

      20.times { |i| push.send("drain-#{i}") }
      push.close

      received = [] of String
      20.times { received << String.new(pull.receive[0]) }

      assert_equal 20, received.size
      assert_equal "drain-0", received.first
      assert_equal "drain-19", received.last

      pull.close
    end
  end

  it "drains inproc strategy queue on linger > 0" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      pull = OMQ::PULL.bind("inproc://linger-inproc")
      push = OMQ::PUSH.new
      push.linger = 1.second
      push.connect("inproc://linger-inproc")

      5.times { |i| push.send("in-#{i}") }
      push.close

      5.times do |i|
        msg = pull.receive
        assert_equal "in-#{i}", String.new(msg[0])
      end

      pull.close
    end
  end
end
