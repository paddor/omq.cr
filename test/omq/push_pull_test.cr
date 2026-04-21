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
      assert_equal "a",   String.new(got[0])
      assert_equal "bb",  String.new(got[1])
      assert_equal "ccc", String.new(got[2])

      push.close
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
