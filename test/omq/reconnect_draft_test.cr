require "../test_helper"
require "../../src/omq/channel"
require "../../src/omq/client_server"
require "../../src/omq/radio_dish"
require "../../src/omq/scatter_gather"
require "../../src/omq/peer"

private def first_peer_id(socket : OMQ::PEER) : Bytes
  OMQ::TestHelper.wait_until { !socket.peer_routing_ids.empty? }
  socket.peer_routing_ids.first
end

describe "Reconnect after TCP server restart for draft sockets" do
  it "reconnects CHANNEL" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      server = OMQ::CHANNEL.bind("tcp://127.0.0.1:0", linger: 0.seconds)
      port = server.port.not_nil!
      client = OMQ::CHANNEL.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds, reconnect_interval: 20.milliseconds)
      OMQ::TestHelper.wait_until { client.peer_count > 0 && server.peer_count > 0 }

      client.send("first")
      assert_equal "first", String.new(server.receive[0])

      server.close
      OMQ::TestHelper.wait_disconnected(client)
      server2 = OMQ::TestHelper.restart_bind_tcp(OMQ::CHANNEL, port)
      OMQ::TestHelper.wait_until { client.peer_count > 0 && server2.peer_count > 0 }

      client.send("second")
      assert_equal "second", String.new(server2.receive[0])

      client.close
      server2.close
    end
  end

  it "reconnects CLIENT/SERVER" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      server = OMQ::SERVER.bind("tcp://127.0.0.1:0", linger: 0.seconds)
      port = server.port.not_nil!
      client = OMQ::CLIENT.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds, reconnect_interval: 20.milliseconds)
      OMQ::TestHelper.wait_until { client.peer_count > 0 && server.peer_count > 0 }

      client.send("req1")
      msg = server.receive
      assert_equal "req1", String.new(msg[1])
      server.send_to(msg[0], "rep1")
      assert_equal "rep1", String.new(client.receive[0])

      server.close
      OMQ::TestHelper.wait_disconnected(client)
      server2 = OMQ::TestHelper.restart_bind_tcp(OMQ::SERVER, port)
      OMQ::TestHelper.wait_until { client.peer_count > 0 && server2.peer_count > 0 }

      client.send("req2")
      msg2 = server2.receive
      assert_equal "req2", String.new(msg2[1])

      client.close
      server2.close
    end
  end

  it "reconnects RADIO/DISH" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      radio = OMQ::RADIO.bind("tcp://127.0.0.1:0", linger: 0.seconds)
      port = radio.port.not_nil!
      dish = OMQ::DISH.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds, reconnect_interval: 20.milliseconds, read_timeout: 1.second)
      dish.join("g")
      radio.subscriber_joined.receive

      radio.publish("g", "first")
      assert_equal ["g", "first"], dish.receive.map { |frame| String.new(frame) }

      radio.close
      OMQ::TestHelper.wait_disconnected(dish)
      radio2 = OMQ::TestHelper.restart_bind_tcp(OMQ::RADIO, port)
      radio2.subscriber_joined.receive

      radio2.publish("g", "second")
      assert_equal ["g", "second"], dish.receive.map { |frame| String.new(frame) }

      dish.close
      radio2.close
    end
  end

  it "reconnects SCATTER/GATHER" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      gather = OMQ::GATHER.bind("tcp://127.0.0.1:0", linger: 0.seconds)
      port = gather.port.not_nil!
      scatter = OMQ::SCATTER.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds, reconnect_interval: 20.milliseconds)
      OMQ::TestHelper.wait_until { scatter.peer_count > 0 && gather.peer_count > 0 }

      scatter.send("first")
      assert_equal "first", String.new(gather.receive[0])

      gather.close
      OMQ::TestHelper.wait_disconnected(scatter)
      gather2 = OMQ::TestHelper.restart_bind_tcp(OMQ::GATHER, port)
      OMQ::TestHelper.wait_until { scatter.peer_count > 0 && gather2.peer_count > 0 }

      scatter.send("second")
      assert_equal "second", String.new(gather2.receive[0])

      scatter.close
      gather2.close
    end
  end

  it "reconnects PEER" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      a = OMQ::PEER.bind("tcp://127.0.0.1:0", linger: 0.seconds)
      port = a.port.not_nil!
      b = OMQ::PEER.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds, reconnect_interval: 20.milliseconds)
      OMQ::TestHelper.wait_until { a.peer_count > 0 && b.peer_count > 0 }

      a.send_to(first_peer_id(a), "hello")
      assert_equal "hello", String.new(b.receive[1])

      a.close
      OMQ::TestHelper.wait_disconnected(b)
      a2 = OMQ::TestHelper.restart_bind_tcp(OMQ::PEER, port)
      OMQ::TestHelper.wait_until { a2.peer_count > 0 && b.peer_count > 0 }

      a2.send_to(first_peer_id(a2), "reconnected")
      assert_equal "reconnected", String.new(b.receive[1])

      b.close
      a2.close
    end
  end
end
