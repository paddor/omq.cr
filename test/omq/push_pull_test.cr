require "../test_helper"

describe "PUSH/PULL over inproc" do
  it "delivers a single message" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://pp-basic")
      push = OMQ::PUSH.connect("inproc://pp-basic")

      push.send("hello")
      got = pull.receive
      assert_equal 1, got.size
      assert_equal "hello", String.new(got[0])

      push.close
      pull.close
    end
  end

  it "work-steals across multiple PULL peers" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      push = OMQ::PUSH.bind("inproc://pp-fanout")

      pulls = Array.new(3) do
        p = OMQ::PULL.new
        p.connect("inproc://pp-fanout")
        p
      end

      total = 60
      collector = Channel(String).new(total)
      pulls.each do |p|
        spawn do
          loop do
            msg = p.receive?
            break unless msg
            collector.send(String.new(msg[0]))
          end
        end
      end

      total.times { |i| push.send("msg-#{i}") }

      received = [] of String
      total.times { received << collector.receive }
      assert_equal total, received.size
      assert_equal total, received.uniq.size

      push.close
      pulls.each(&.close)
    end
  end

  it "delivers multiframe messages" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://pp-multi")
      push = OMQ::PUSH.connect("inproc://pp-multi")

      push.send(["a".to_slice, "bb".to_slice, "ccc".to_slice])
      got = pull.receive
      assert_equal 3, got.size
      assert_equal "a", String.new(got[0])
      assert_equal "bb", String.new(got[1])
      assert_equal "ccc", String.new(got[2])

      push.close
      pull.close
    end
  end

  it "delivers queued messages when connect happens before bind" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      push = OMQ::PUSH.connect("inproc://pp-connect-before-bind", linger: 1.second)
      push.send("early-1")
      push.send("early-2")

      pull = OMQ::PULL.bind("inproc://pp-connect-before-bind")
      push.send("late")

      assert_equal "early-1", String.new(pull.receive[0])
      assert_equal "early-2", String.new(pull.receive[0])
      assert_equal "late", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end

  it "does not deadlock binding after many pending connects" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pushes = Array.new(80) do |i|
        push = OMQ::PUSH.connect("inproc://pp-many-pending", linger: 1.second)
        push.send("pending-#{i}")
        push
      end

      pull = OMQ::PULL.bind("inproc://pp-many-pending")
      received = [] of String
      80.times { received << String.new(pull.receive[0]) }

      assert_equal 80, received.size
      assert_equal 80, received.uniq.size

      pushes.each(&.close)
      pull.close
    end
  end
end

describe "PUSH/PULL over TCP" do
  it "delivers messages over an ephemeral port" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!
      push = OMQ::PUSH.connect("tcp://127.0.0.1:#{port}")

      10.times { |i| push.send("msg-#{i}") }
      10.times do |i|
        got = pull.receive
        assert_equal "msg-#{i}", String.new(got[0])
      end

      push.close
      pull.close
    end
  end
end
