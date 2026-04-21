require "../test_helper"
require "../../src/omq/client_server"

describe "CLIENT/SERVER over inproc" do
  it "echoes a request and reply via routing ID" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      srv    = OMQ::SERVER.bind("inproc://cs-basic")
      client = OMQ::CLIENT.connect("inproc://cs-basic")

      client.send("ping")
      msg = srv.receive
      assert_equal 2, msg.size
      routing_id = msg[0]
      assert_equal 4, routing_id.size
      assert_equal "ping", String.new(msg[1])

      srv.send_to(routing_id, "pong")
      reply = client.receive
      assert_equal 1, reply.size
      assert_equal "pong", String.new(reply[0])

      client.close
      srv.close
    end
  end


  it "routes replies to distinct clients by routing ID" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      srv = OMQ::SERVER.bind("inproc://cs-route")
      c1  = OMQ::CLIENT.connect("inproc://cs-route")
      c2  = OMQ::CLIENT.connect("inproc://cs-route")

      c1.send("from-1")
      c2.send("from-2")

      a = srv.receive
      b = srv.receive

      srv.send_to(a[0], "reply-a")
      srv.send_to(b[0], "reply-b")

      got_c1 = String.new(c1.receive[0])
      got_c2 = String.new(c2.receive[0])

      # The reply paired with c1's send should land at c1, same for c2.
      if String.new(a[1]) == "from-1"
        assert_equal "reply-a", got_c1
        assert_equal "reply-b", got_c2
      else
        assert_equal "reply-b", got_c1
        assert_equal "reply-a", got_c2
      end

      c1.close
      c2.close
      srv.close
    end
  end


end
