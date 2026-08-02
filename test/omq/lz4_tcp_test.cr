require "../test_helper"

private def lz4_json_msg(i : Int32) : Bytes
  %({"event":"login","user":"user_#{i}","ts":"2026-08-03T00:00:00.#{i}Z","region":"us-east-1","status":200}).to_slice
end

private def lz4_endpoint(socket : OMQ::Socket) : String
  "lz4+tcp://127.0.0.1:#{socket.port.not_nil!}"
end

describe "lz4+tcp transport" do
  it "round-trips a small payload below the compression threshold" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("lz4+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect(lz4_endpoint(pull))

      push.send("hi")
      assert_equal "hi", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end

  it "round-trips a compressible payload" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("lz4+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect(lz4_endpoint(pull))
      payload = ("A" * 4096).to_slice

      push.send(payload)
      assert_equal payload, pull.receive[0]

      push.close
      pull.close
    end
  end

  it "round-trips multipart messages" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("lz4+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect(lz4_endpoint(pull))
      parts = ["header".to_slice, ("body " * 300).to_slice, "trailer".to_slice]

      push.send(parts)
      assert_equal parts, pull.receive

      push.close
      pull.close
    end
  end

  it "ships a configured send-side dictionary once" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      dict = ("event=login user=alice payload=" * 10).to_slice
      pull = OMQ::PULL.bind("lz4+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect(lz4_endpoint(pull), dict: dict)
      msg1 = ("event=login user=alice payload=first" * 8).to_slice
      msg2 = ("event=login user=alice payload=second" * 8).to_slice

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
      pull = OMQ::PULL.bind("lz4+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect(lz4_endpoint(pull), auto_dict: {capacity: 2048, trigger: 5})

      8.times { |i| push.send(lz4_json_msg(i)) }
      8.times { |i| assert_equal lz4_json_msg(i), pull.receive[0] }

      push.close
      pull.close
    end
  end

  it "stays in no-dict mode when auto training has no usable samples" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.bind("lz4+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect(lz4_endpoint(pull), auto_dict: {trigger: 5})

      8.times { push.send("hi") }
      8.times { assert_equal "hi", String.new(pull.receive[0]) }

      push.close
      pull.close
    end
  end

  it "applies max_message_size to decompressed multipart size" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.new(read_timeout: 100.milliseconds, max_message_size: 2000_i64)
      pull.bind("lz4+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect(lz4_endpoint(pull))

      push.send([("A" * 1024).to_slice, ("B" * 1024).to_slice, ("C" * 1024).to_slice])

      assert_raises(IO::TimeoutError) { pull.receive }

      push.close
      pull.close
    end
  end

  it "rejects invalid dictionary options" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      oversized = Bytes.new(OMQ::Transport::Lz4Tcp::Codec::MAX_DICT_SIZE + 1)

      assert_raises(OMQ::Transport::Lz4Tcp::ProtocolError) do
        OMQ::PULL.bind("lz4+tcp://127.0.0.1:0", dict: oversized)
      end
      assert_raises(ArgumentError) do
        OMQ::PULL.bind("lz4+tcp://127.0.0.1:0", dict: "some dict bytes", auto_dict: true)
      end
      assert_raises(ArgumentError) do
        OMQ::PULL.bind("lz4+tcp://127.0.0.1:0", auto_dict: {capacity: 16_384})
      end
    end
  end

  it "does not accept plain tcp data frames as lz4+tcp payloads" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.new(read_timeout: 100.milliseconds)
      pull.bind("lz4+tcp://127.0.0.1:0")
      push = OMQ::PUSH.connect("tcp://127.0.0.1:#{pull.port.not_nil!}", reconnect_interval: 1.hour)

      push.send("plain")

      assert_raises(IO::TimeoutError) { pull.receive }

      push.close
      pull.close
    end
  end
end
