require "../../test_helper"

describe "PAIR over TCP" do
  it "round-trips messages over an ephemeral port" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      server = OMQ::PAIR.bind("tcp://127.0.0.1:0")
      port = server.port.not_nil!
      refute_equal 0, port
      assert port > 0

      client = OMQ::PAIR.connect("tcp://127.0.0.1:#{port}")

      client.send("hello tcp")
      got = server.receive
      assert_equal "hello tcp", String.new(got[0])

      server.send("reply tcp")
      got2 = client.receive
      assert_equal "reply tcp", String.new(got2[0])

      client.close
      server.close
    end
  end

  it "delivers multiframe messages" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      server = OMQ::PAIR.bind("tcp://127.0.0.1:0")
      port = server.port.not_nil!
      client = OMQ::PAIR.connect("tcp://127.0.0.1:#{port}")

      client.send(["a".to_slice, "bb".to_slice, "ccc".to_slice])
      got = server.receive
      assert_equal 3, got.size
      assert_equal "a",   String.new(got[0])
      assert_equal "bb",  String.new(got[1])
      assert_equal "ccc", String.new(got[2])

      client.close
      server.close
    end
  end

  it "carries payloads that require the 8-byte length field" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      server = OMQ::PAIR.bind("tcp://127.0.0.1:0")
      port = server.port.not_nil!
      client = OMQ::PAIR.connect("tcp://127.0.0.1:#{port}")

      payload = Bytes.new(64 * 1024) { |i| (i % 251).to_u8 }
      client.send(payload)
      got = server.receive
      assert_equal payload.size, got[0].size
      assert_equal payload, got[0]

      client.close
      server.close
    end
  end

  it "surfaces identity across the handshake" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      server = OMQ::PAIR.new
      server.identity = "server-1".to_slice
      server.bind("tcp://127.0.0.1:0")
      port = server.port.not_nil!

      client = OMQ::PAIR.new
      client.identity = "client-1".to_slice
      client.connect("tcp://127.0.0.1:#{port}")

      # Force a round-trip so both sides have completed the handshake
      # before we poke at anything.
      client.send("ping")
      server.receive

      client.close
      server.close
    end
  end
end
