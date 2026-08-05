require "../test_helper"
require "../../src/omq/peer"

describe "PEER over inproc" do
  it "exchanges addressed messages between two PEER sockets" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      a = OMQ::PEER.bind("inproc://peer-basic")
      b = OMQ::PEER.connect("inproc://peer-basic")

      # a assigned b a routing ID on attach; grab it and send first.
      OMQ::TestHelper.wait_until { !a.peer_routing_ids.empty? }
      ids = a.peer_routing_ids
      b_id_on_a = ids[0]

      a.send_to(b_id_on_a, "ping")
      msg = b.receive
      a_id_on_b = msg[0]
      assert_equal "ping", String.new(msg[1])

      b.send_to(a_id_on_b, "pong")
      reply = a.receive
      assert_equal b_id_on_a, reply[0]
      assert_equal "pong", String.new(reply[1])

      a.close
      b.close
    end
  end

  it "uses a PEER identity as the routing ID" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      a = OMQ::PEER.bind("inproc://peer-identity")
      b = OMQ::PEER.connect("inproc://peer-identity", identity: "peer-b")

      OMQ::TestHelper.wait_until { a.peer_routing_ids.any? { |id| String.new(id) == "peer-b" } }

      a.send_to("peer-b".to_slice, "ping")
      msg = b.receive
      assert_equal "ping", String.new(msg[1])

      a.close
      b.close
    end
  end
end
