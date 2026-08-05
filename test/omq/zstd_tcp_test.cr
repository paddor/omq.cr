require "../test_helper"

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
