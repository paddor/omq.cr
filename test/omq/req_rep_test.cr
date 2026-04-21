require "../test_helper"

describe "REQ/REP over inproc" do
  it "round-trips a single request/reply" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      rep = OMQ::REP.bind("inproc://rr-basic")
      req = OMQ::REQ.connect("inproc://rr-basic")

      req.send("ping")
      request = rep.receive
      assert_equal 1, request.size
      assert_equal "ping", String.new(request[0])

      rep.send("pong")
      reply = req.receive
      assert_equal 1, reply.size
      assert_equal "pong", String.new(reply[0])

      req.close
      rep.close
    end
  end

  it "alternates across many round trips" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      rep = OMQ::REP.bind("inproc://rr-loop")
      req = OMQ::REQ.connect("inproc://rr-loop")

      100.times do |i|
        req.send("q-#{i}")
        request = rep.receive
        assert_equal "q-#{i}", String.new(request[0])
        rep.send("a-#{i}")
        reply = req.receive
        assert_equal "a-#{i}", String.new(reply[0])
      end

      req.close
      rep.close
    end
  end

  it "preserves multiframe request/reply bodies" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      rep = OMQ::REP.bind("inproc://rr-multi")
      req = OMQ::REQ.connect("inproc://rr-multi")

      req.send(["method".to_slice, "GET".to_slice, "/foo".to_slice])
      request = rep.receive
      assert_equal 3, request.size
      assert_equal "method", String.new(request[0])
      assert_equal "GET",    String.new(request[1])
      assert_equal "/foo",   String.new(request[2])

      rep.send(["200".to_slice, "OK".to_slice])
      reply = req.receive
      assert_equal 2, reply.size
      assert_equal "200", String.new(reply[0])
      assert_equal "OK",  String.new(reply[1])

      req.close
      rep.close
    end
  end
end

describe "REQ/REP over TCP" do
  it "round-trips across a TCP hop" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      rep = OMQ::REP.bind("tcp://127.0.0.1:0")
      port = rep.port.not_nil!
      req = OMQ::REQ.connect("tcp://127.0.0.1:#{port}")

      5.times do |i|
        req.send("q-#{i}")
        got = rep.receive
        assert_equal "q-#{i}", String.new(got[0])
        rep.send("a-#{i}")
        reply = req.receive
        assert_equal "a-#{i}", String.new(reply[0])
      end

      req.close
      rep.close
    end
  end
end
