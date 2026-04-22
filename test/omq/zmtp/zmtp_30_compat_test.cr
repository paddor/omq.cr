require "../../test_helper"
require "socket"


# A raw peer that drives the TCP wire manually so we can advertise an
# arbitrary ZMTP minor version (0 or 1) and inspect what the Crystal
# side sends back.
private class FakePeer
  getter server : TCPServer
  getter port : Int32
  getter accepted : ::Channel(TCPSocket)


  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    @accepted = ::Channel(TCPSocket).new(1)
  end


  # Accept one connection, perform the greeting + READY handshake as a
  # peer advertising ZMTP 3.`minor`. The caller can then read further
  # frames off the returned socket with `OMQ::ZMTP::Frame.decode`.
  def serve(minor : UInt8, *, peer_socket_type : String) : Nil
    spawn do
      sock = @server.accept
      sock.sync = false
      # Greeting with a forced minor version.
      OMQ::ZMTP::Greeting.new(3_u8, minor, "NULL", true).to_io(sock)
      sock.flush

      # Read remote greeting; we don't care about its contents.
      remote = Bytes.new(OMQ::ZMTP::GREETING_SIZE)
      sock.read_fully(remote)

      # Exchange READY.
      ready = OMQ::ZMTP::Command.ready(peer_socket_type)
      OMQ::ZMTP::Frame.encode(sock, ready, command: true)
      sock.flush

      payload, _more, is_command = OMQ::ZMTP::Frame.decode(sock)
      raise "expected READY command from peer" unless is_command
      name, _body = OMQ::ZMTP::Command.parse(payload)
      raise "expected READY, got #{name}" unless name == "READY"

      @accepted.send(sock)
    end
  end


  def close : Nil
    @server.close unless @server.closed?
  end
end


describe "ZMTP 3.0 wire compatibility" do
  it "SUB sends SUBSCRIBE as a COMMAND frame to a 3.1 peer" do
    peer = FakePeer.new
    peer.serve(1_u8, peer_socket_type: "PUB")

    OMQ::TestHelper.with_timeout(2.seconds) do
      sub = OMQ::SUB.new
      sub.connect("tcp://127.0.0.1:#{peer.port}")
      sock = peer.accepted.receive
      sub.subscribe("weather")

      payload, _more, is_command = OMQ::ZMTP::Frame.decode(sock)
      assert is_command, "expected COMMAND frame, got data"
      name, body = OMQ::ZMTP::Command.parse(payload)
      assert_equal "SUBSCRIBE", name
      assert_equal "weather", String.new(body)

      sub.close
      sock.close
    end
  ensure
    peer.try(&.close)
  end


  it "SUB sends \\x01prefix as a DATA frame to a 3.0 peer" do
    peer = FakePeer.new
    peer.serve(0_u8, peer_socket_type: "PUB")

    OMQ::TestHelper.with_timeout(2.seconds) do
      sub = OMQ::SUB.new
      sub.connect("tcp://127.0.0.1:#{peer.port}")
      sock = peer.accepted.receive
      sub.subscribe("weather")

      payload, _more, is_command = OMQ::ZMTP::Frame.decode(sock)
      refute is_command, "expected DATA frame, got COMMAND"
      assert_equal 0x01_u8, payload[0]
      assert_equal "weather", String.new(payload[1..])

      sub.close
      sock.close
    end
  ensure
    peer.try(&.close)
  end


  it "SUB sends \\x00prefix on unsubscribe to a 3.0 peer" do
    peer = FakePeer.new
    peer.serve(0_u8, peer_socket_type: "PUB")

    OMQ::TestHelper.with_timeout(2.seconds) do
      sub = OMQ::SUB.new
      sub.connect("tcp://127.0.0.1:#{peer.port}")
      sock = peer.accepted.receive

      sub.subscribe("weather")
      OMQ::ZMTP::Frame.decode(sock) # consume the subscribe frame

      sub.unsubscribe("weather")
      payload, _more, is_command = OMQ::ZMTP::Frame.decode(sock)
      refute is_command
      assert_equal 0x00_u8, payload[0]
      assert_equal "weather", String.new(payload[1..])

      sub.close
      sock.close
    end
  ensure
    peer.try(&.close)
  end


  it "does not send PING to a 3.0 peer even with heartbeat_interval set" do
    peer = FakePeer.new
    peer.serve(0_u8, peer_socket_type: "PAIR")

    OMQ::TestHelper.with_timeout(2.seconds) do
      pair = OMQ::PAIR.new
      pair.options.heartbeat_interval = 50.milliseconds
      pair.connect("tcp://127.0.0.1:#{peer.port}")
      sock = peer.accepted.receive

      # Give the heartbeat pump three intervals' worth of wall-clock
      # time to prove itself idle. If it were running we'd see PING
      # commands arrive on `sock`.
      sleep 200.milliseconds

      # Non-blocking read: if the peer fiber wrote anything, it's here.
      # We expect zero bytes — nothing queued.
      buf = Bytes.new(1)
      sock.read_timeout = 50.milliseconds
      got_bytes = false
      begin
        n = sock.read(buf)
        got_bytes = n > 0
      rescue IO::TimeoutError
        got_bytes = false
      end
      refute got_bytes, "PING should not be sent to a ZMTP 3.0 peer"

      pair.close
      sock.close
    end
  ensure
    peer.try(&.close)
  end
end
