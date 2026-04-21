require "../test_helper"

describe "max_message_size" do
  it "rejects oversized frames over TCP" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      rep = OMQ::REP.new
      rep.max_message_size = 10_i64
      rep.bind("tcp://127.0.0.1:0")
      port = rep.port.not_nil!

      req = OMQ::REQ.new
      req.reconnect_interval = 1.hour
      req.connect("tcp://127.0.0.1:#{port}")

      req.send("hi")
      msg = rep.receive
      assert_equal "hi", String.new(msg[0])
      rep.send("ok")
      req.receive

      req.send("x" * 100)

      rep.read_timeout = 50.milliseconds
      assert_raises(IO::TimeoutError) { rep.receive }

      req.close
      rep.close
    end
  end

  it "allows messages within limit" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      rep = OMQ::REP.new
      rep.max_message_size = 1024_i64
      rep.bind("tcp://127.0.0.1:0")
      port = rep.port.not_nil!

      req = OMQ::REQ.new
      req.connect("tcp://127.0.0.1:#{port}")

      req.send("x" * 500)
      msg = rep.receive
      assert_equal 500, msg[0].size

      req.close
      rep.close
    end
  end

  it "accepts messages exactly at the limit" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      rep = OMQ::REP.new
      rep.max_message_size = 100_i64
      rep.bind("tcp://127.0.0.1:0")
      port = rep.port.not_nil!

      req = OMQ::REQ.new
      req.connect("tcp://127.0.0.1:#{port}")

      req.send("x" * 100)
      msg = rep.receive
      assert_equal 100, msg[0].size

      req.close
      rep.close
    end
  end

  it "has no limit by default" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      rep = OMQ::REP.new
      rep.bind("tcp://127.0.0.1:0")
      port = rep.port.not_nil!

      req = OMQ::REQ.new
      req.connect("tcp://127.0.0.1:#{port}")

      assert_nil rep.max_message_size
      big_size = 4 * 1024 * 1024
      req.send("x" * big_size)
      msg = rep.receive
      assert_equal big_size, msg[0].size

      req.close
      rep.close
    end
  end

  it "rejects when one frame in a multi-frame message exceeds limit" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      rep = OMQ::REP.new
      rep.max_message_size = 50_i64
      rep.bind("tcp://127.0.0.1:0")
      port = rep.port.not_nil!

      req = OMQ::REQ.new
      req.reconnect_interval = 1.hour
      req.connect("tcp://127.0.0.1:#{port}")

      req.send(["small".to_slice, ("x" * 100).to_slice])

      rep.read_timeout = 50.milliseconds
      assert_raises(IO::TimeoutError) { rep.receive }

      req.close
      rep.close
    end
  end
end
