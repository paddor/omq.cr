require "../test_helper"

describe "STREAM over raw TCP" do
  it "round-trips raw bytes with identity routing" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      stream = OMQ::STREAM.bind("tcp://127.0.0.1:0")
      client = TCPSocket.new("127.0.0.1", stream.port.not_nil!)

      connected = stream.receive
      identity = connected[0]
      refute identity.empty?
      assert_empty connected[1]

      client.write("hello stream".to_slice)

      inbound = stream.receive
      assert_equal identity, inbound[0]
      assert_equal "hello stream", String.new(inbound[1])

      stream.send([identity, "reply back".to_slice])

      buf = Bytes.new("reply back".bytesize)
      client.read_fully(buf)
      assert_equal "reply back", String.new(buf)

      client.close
      stream.close
    end
  end

  it "round-trips large raw payloads" do
    OMQ::TestHelper.with_timeout(4.seconds) do
      stream = OMQ::STREAM.bind("tcp://127.0.0.1:0")
      client = TCPSocket.new("127.0.0.1", stream.port.not_nil!)

      connected = stream.receive
      identity = connected[0]
      assert_empty connected[1]

      payload = Bytes.new(128 * 1024) { |i| (i % 251).to_u8 }
      client.write(payload)

      got = Bytes.new(payload.size)
      offset = 0
      while offset < got.size
        msg = stream.receive
        assert_equal identity, msg[0]
        refute_empty msg[1]
        msg[1].copy_to(got[offset, msg[1].size])
        offset += msg[1].size
      end
      assert_equal payload, got

      reply = Bytes.new(payload.size) { |i| (payload[i] ^ 0xA5).to_u8 }
      stream.send_to(identity, reply)

      got_reply = Bytes.new(reply.size)
      client.read_fully(got_reply)
      assert_equal reply, got_reply

      client.close
      stream.close
    end
  end

  it "notifies when a peer disconnects" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      stream = OMQ::STREAM.bind("tcp://127.0.0.1:0")
      client = TCPSocket.new("127.0.0.1", stream.port.not_nil!)

      connected = stream.receive
      identity = connected[0]
      client.close

      disconnected = stream.receive
      assert_equal identity, disconnected[0]
      assert_empty disconnected[1]

      stream.close
    end
  end

  it "routes multiple raw peers by identity" do
    OMQ::TestHelper.with_timeout(4.seconds) do
      stream = OMQ::STREAM.bind("tcp://127.0.0.1:0")
      clients = [] of TCPSocket
      identities = [] of Bytes

      3.times do
        client = TCPSocket.new("127.0.0.1", stream.port.not_nil!)
        clients << client
        connected = stream.receive
        refute connected[0].empty?
        assert_empty connected[1]
        identities << connected[0]
      end

      clients.each_with_index do |client, i|
        client.write("msg-#{i}".to_slice)
      end

      received = {} of String => String
      3.times do
        msg = stream.receive
        received[msg[0].hexstring] = String.new(msg[1])
      end

      identities.each_with_index do |identity, i|
        assert_equal "msg-#{i}", received[identity.hexstring]
      end

      identities.each_with_index do |identity, i|
        stream.send_to(identity, "reply-#{i}")
      end

      clients.each_with_index do |client, i|
        expected = "reply-#{i}"
        buf = Bytes.new(expected.bytesize)
        client.read_fully(buf)
        assert_equal expected, String.new(buf)
      end

      clients.each(&.close)
      stream.close
    end
  end

  it "closes a peer on empty data send" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      stream = OMQ::STREAM.bind("tcp://127.0.0.1:0")
      client = TCPSocket.new("127.0.0.1", stream.port.not_nil!)

      connected = stream.receive
      identity = connected[0]
      stream.send([identity, Bytes.empty])

      buf = Bytes.new(16)
      assert_equal 0, client.read(buf)

      client.close
      stream.close
    end
  end

  it "validates send frame count and optional mandatory routing" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      stream = OMQ::STREAM.bind("tcp://127.0.0.1:0", router_mandatory: true)
      unknown = Bytes[1, 2, 3, 4, 5]

      assert_raises(ArgumentError) do
        stream.send([unknown])
      end

      assert_raises(ArgumentError) do
        stream.send([unknown, "data".to_slice, "extra".to_slice])
      end

      assert_raises(OMQ::Error) do
        stream.send([unknown, "data".to_slice])
      end

      stream.close
    end

    OMQ::TestHelper.with_timeout(3.seconds) do
      stream = OMQ::STREAM.bind("tcp://127.0.0.1:0")
      stream.send([Bytes[9, 8, 7, 6, 5], "dropped".to_slice])
      stream.close
    end
  end

  it "connects to a raw TCP listener" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      listener = TCPServer.new("127.0.0.1", 0)
      stream = OMQ::STREAM.connect("tcp://127.0.0.1:#{listener.local_address.port}")
      peer = listener.accept

      connected = stream.receive
      identity = connected[0]
      refute identity.empty?
      assert_empty connected[1]

      peer.write("from server".to_slice)

      inbound = stream.receive
      assert_equal identity, inbound[0]
      assert_equal "from server", String.new(inbound[1])

      stream.send_to(identity, "from stream")

      buf = Bytes.new("from stream".bytesize)
      peer.read_fully(buf)
      assert_equal "from stream", String.new(buf)

      peer.close
      listener.close
      stream.close
    end
  end

  it "rejects non-TCP endpoints" do
    assert_raises(OMQ::UnsupportedTransport) do
      OMQ::STREAM.bind("inproc://stream-test")
    end

    assert_raises(OMQ::UnsupportedTransport) do
      OMQ::STREAM.connect("ipc:///tmp/omq-stream-test.sock")
    end

    assert_raises(OMQ::UnsupportedTransport) do
      OMQ::STREAM.connect("udp://127.0.0.1:5555")
    end
  end
end
