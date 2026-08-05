require "../test_helper"
require "../../src/omq/curve"

private def zstd_tcp_json_msg(i : Int32) : Bytes
  %({"event":"login","user":"user_#{i}","ts":"2026-08-06T00:00:00.#{i}Z","region":"us-east-1","status":200}).to_slice
end

private def zstd_tcp_training_dict : Bytes
  trainer = Zinc::DictTrainer.new(2048)
  40.times { |i| trainer.add_sample(zstd_tcp_json_msg(i)) }
  trainer.train
end

private def zstd_endpoint(socket : OMQ::Socket) : String
  "zstd+tcp://127.0.0.1:#{socket.port.not_nil!}"
end

private def zstd_bind_pull(port : Int32) : OMQ::PULL
  deadline = Time.instant + 2.seconds
  loop do
    begin
      return OMQ::PULL.bind("zstd+tcp://127.0.0.1:#{port}", linger: 0.seconds)
    rescue ex : IO::Error
      raise ex if Time.instant >= deadline
      sleep 1.millisecond
    end
  end
end

private def zstd_raw_push(port : Int32) : OMQ::ZMTP::Connection
  tcp = TCPSocket.new("127.0.0.1", port)
  raw = OMQ::ZMTP::Connection.new(tcp)
  raw.handshake(
    local_socket_type: "PUSH",
    local_identity: Bytes.empty,
    as_server: false,
  )
  raw
end

private def zstd_curve_keypair
  sk = Natron::PrivateKey.generate
  {sk.public_key.bytes, sk.bytes}
end

describe "zstd+tcp transport" do
  it "round-trips a small payload below the compression threshold" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("zstd+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect(zstd_endpoint(pull))

      push.send("hi")
      assert_equal "hi", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end

  it "round-trips a compressible payload" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("zstd+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect(zstd_endpoint(pull))
      payload = ("A" * 4096).to_slice

      push.send(payload)
      assert_equal payload, pull.receive[0]

      push.close
      pull.close
    end
  end

  it "round-trips multipart messages" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("zstd+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect(zstd_endpoint(pull))
      parts = ["header".to_slice, ("body " * 300).to_slice, "trailer".to_slice]

      push.send(parts)
      assert_equal parts, pull.receive

      push.close
      pull.close
    end
  end

  it "passes ZMTP command frames without compression" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pub = OMQ::PUB.bind("zstd+tcp://127.0.0.1:0")
      sub = OMQ::SUB.connect(zstd_endpoint(pub), subscribe: "news")

      pub.subscriber_joined.receive
      pub.send(["sports".to_slice, "drop".to_slice])
      pub.send(["news".to_slice, "keep".to_slice])

      assert_equal ["news", "keep"], sub.receive.map { |part| String.new(part) }

      sub.close
      pub.close
    end
  end

  it "ships a configured ZDICT dictionary before dict-compressed messages" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      dict = zstd_tcp_training_dict
      pull = OMQ::PULL.bind("zstd+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect(zstd_endpoint(pull), zstd_dict: dict)
      msg1 = (String.new(zstd_tcp_json_msg(1)) * 20).to_slice
      msg2 = (String.new(zstd_tcp_json_msg(2)) * 20).to_slice

      push.send(msg1)
      push.send(msg2)

      assert_equal msg1, pull.receive[0]
      assert_equal msg2, pull.receive[0]

      push.close
      pull.close
    end
  end

  it "re-ships a configured dictionary after reconnect" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      dict = zstd_tcp_training_dict
      pull = OMQ::PULL.bind("zstd+tcp://127.0.0.1:0", linger: 0.seconds)
      port = pull.port.not_nil!
      push = OMQ::PUSH.connect(
        "zstd+tcp://127.0.0.1:#{port}",
        zstd_dict: dict,
        linger: 0.seconds,
        reconnect_interval: 20.milliseconds,
      )
      first = (String.new(zstd_tcp_json_msg(10)) * 20).to_slice
      second = (String.new(zstd_tcp_json_msg(11)) * 20).to_slice

      push.send(first)
      assert_equal first, pull.receive[0]

      pull.close
      OMQ::TestHelper.wait_disconnected(push)
      pull2 = zstd_bind_pull(port)
      OMQ::TestHelper.wait_until { push.peer_count > 0 && pull2.peer_count > 0 }

      push.send(second)
      assert_equal second, pull2.receive[0]

      push.close
      pull2.close
    end
  end

  it "auto-trains a send-side dictionary and keeps messages readable" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      pull = OMQ::PULL.bind("zstd+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect(
        zstd_endpoint(pull),
        zstd_auto_dict: OMQ::Transport::ZstdTcp::AutoDict.new(capacity: 2048, max_samples: 5),
      )

      8.times { |i| push.send(zstd_tcp_json_msg(i)) }
      8.times { |i| assert_equal zstd_tcp_json_msg(i), pull.receive[0] }

      push.close
      pull.close
    end
  end

  it "serves a late subscriber after auto-training a dictionary" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      pub = OMQ::PUB.bind(
        "zstd+tcp://127.0.0.1:0",
        zstd_auto_dict: OMQ::Transport::ZstdTcp::AutoDict.new(capacity: 2048, max_samples: 5),
      )
      sub1 = OMQ::SUB.connect(zstd_endpoint(pub), subscribe: "", read_timeout: 1.second)
      pub.subscriber_joined.receive

      8.times { |i| pub.send(zstd_tcp_json_msg(i)) }
      8.times { |i| assert_equal zstd_tcp_json_msg(i), sub1.receive[0] }

      sub2 = OMQ::SUB.connect(zstd_endpoint(pub), subscribe: "", read_timeout: 1.second)
      pub.subscriber_joined.receive
      payload = (String.new(zstd_tcp_json_msg(42)) * 20).to_slice

      pub.send(payload)
      assert_equal payload, sub1.receive[0]
      assert_equal payload, sub2.receive[0]

      sub2.close
      sub1.close
      pub.close
    end
  end

  it "rejects duplicate dictionary shipments from a peer" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.new(read_timeout: 150.milliseconds)
      pull.bind("zstd+tcp://127.0.0.1:0")
      raw = zstd_raw_push(pull.port.not_nil!)
      dict = zstd_tcp_training_dict

      raw.send_message([dict])
      raw.send_message([dict])

      assert_raises(IO::TimeoutError) { pull.receive }

      raw.close
      pull.close
    end
  end

  it "rejects malformed zstd frames from a peer" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.new(read_timeout: 150.milliseconds)
      pull.bind("zstd+tcp://127.0.0.1:0")
      raw = zstd_raw_push(pull.port.not_nil!)

      raw.send_message([OMQ::Transport::ZstdTcp::Codec::ZSTD_MAGIC + Bytes[0_u8, 0_u8]])

      assert_raises(IO::TimeoutError) { pull.receive }

      raw.close
      pull.close
    end
  end

  it "round-trips zstd+tcp over CURVE" do
    server_pub, server_sec = zstd_curve_keypair
    client_pub, client_sec = zstd_curve_keypair

    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.new
      pull.mechanism = OMQ::ZMTP::Mechanism::Curve.server(public_key: server_pub, secret_key: server_sec)
      pull.bind("zstd+tcp://127.0.0.1:0")

      push = OMQ::PUSH.new
      push.mechanism = OMQ::ZMTP::Mechanism::Curve.client(
        server_key: server_pub,
        public_key: client_pub,
        secret_key: client_sec,
      )
      push.connect(zstd_endpoint(pull))
      payload = ("curve-zstd " * 400).to_slice

      push.send(payload)
      assert_equal payload, pull.receive[0]

      push.close
      pull.close
    end
  end

  it "applies max_message_size to decompressed multipart size" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.new(read_timeout: 100.milliseconds, max_message_size: 2000_i64)
      pull.bind("zstd+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect(zstd_endpoint(pull))

      push.send([("A" * 1024).to_slice, ("B" * 1024).to_slice, ("C" * 1024).to_slice])

      assert_raises(IO::TimeoutError) { pull.receive }

      push.close
      pull.close
    end
  end

  it "rejects invalid dictionary options" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      oversized = Bytes.new(OMQ::Transport::ZstdTcp::Codec::MAX_DICT_SIZE + 1)

      assert_raises(OMQ::Transport::ZstdTcp::ProtocolError) do
        OMQ::PULL.bind("zstd+tcp://127.0.0.1:0", zstd_dict: "raw dict bytes")
      end
      assert_raises(OMQ::Transport::ZstdTcp::ProtocolError) do
        OMQ::PULL.bind("zstd+tcp://127.0.0.1:0", zstd_dict: oversized)
      end
      assert_raises(ArgumentError) do
        OMQ::PULL.bind("zstd+tcp://127.0.0.1:0", zstd_dict: zstd_tcp_training_dict, zstd_auto_dict: true)
      end
      assert_raises(ArgumentError) do
        OMQ::PULL.bind("zstd+tcp://127.0.0.1:0", zstd_auto_dict: {capacity: 16_384})
      end
    end
  end

  it "does not accept plain tcp data frames as zstd+tcp payloads" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.new(read_timeout: 100.milliseconds)
      pull.bind("zstd+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect("tcp://127.0.0.1:#{pull.port.not_nil!}", reconnect_interval: 1.hour)

      push.send("plain")

      assert_raises(IO::TimeoutError) { pull.receive }

      push.close
      pull.close
    end
  end
end
