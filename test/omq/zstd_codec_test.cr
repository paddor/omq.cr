require "../test_helper"

private alias ZstdTcp = OMQ::Transport::ZstdTcp

private def zstd_patterned_bytes(size : Int32) : Bytes
  Bytes.new(size) { |i| ((i * 17 + size) % 251).to_u8 }
end

private def zstd_training_dict : Bytes
  trainer = Zinc::DictTrainer.new(2048)
  40.times do |i|
    trainer.add_sample(%({"event":"login","user":"user_#{i}","region":"us-east-1","status":200}).to_slice)
  end
  trainer.train
end

describe "ZstdTcp::Codec" do
  it "round-trips small and large parts" do
    send_codec = Zinc::FrameCodec.new(level: ZstdTcp::Codec::DEFAULT_LEVEL)
    recv_codec = Zinc::FrameCodec.new

    [0, 1, 64, 512, 4096, 65_536].each do |size|
      payload = zstd_patterned_bytes(size)
      wire = ZstdTcp::Codec.encode_part(payload, frame_codec: send_codec, min_size: 0)

      assert_equal payload, ZstdTcp::Codec.decode_part(wire, frame_codec: recv_codec)
    end
  end

  it "passes through payloads below the compression threshold" do
    send_codec = Zinc::FrameCodec.new(level: ZstdTcp::Codec::DEFAULT_LEVEL)
    recv_codec = Zinc::FrameCodec.new
    wire = ZstdTcp::Codec.encode_part("hello".to_slice, frame_codec: send_codec)

    assert_equal ZstdTcp::Codec::UNCOMPRESSED_SENTINEL, wire[0, 4]
    assert_equal "hello", String.new(ZstdTcp::Codec.decode_part(wire, frame_codec: recv_codec))
  end

  it "emits standard Zstandard frames with Frame_Content_Size" do
    send_codec = Zinc::FrameCodec.new(level: ZstdTcp::Codec::DEFAULT_LEVEL)
    recv_codec = Zinc::FrameCodec.new
    payload = ("A" * 4096).to_slice
    wire = ZstdTcp::Codec.encode_part(payload, frame_codec: send_codec)

    assert_equal ZstdTcp::Codec::ZSTD_MAGIC, wire[0, 4]
    assert_equal payload.size.to_u64, ZstdTcp::Codec.parse_frame_content_size(wire)
    assert_equal payload, ZstdTcp::Codec.decode_part(wire, frame_codec: recv_codec)
  end

  it "round-trips with a shipped ZDICT dictionary" do
    dict = zstd_training_dict
    send_codec = Zinc::FrameCodec.new(dict: dict, level: ZstdTcp::Codec::DEFAULT_LEVEL)
    recv_codec = Zinc::FrameCodec.new(dict: dict)
    no_dict_codec = Zinc::FrameCodec.new
    payload = (%({"event":"login","user":"user_17","region":"us-east-1","status":200}) * 20).to_slice

    wire = ZstdTcp::Codec.encode_part(payload, frame_codec: send_codec, min_size: 0)

    assert_equal ZstdTcp::Codec::ZSTD_MAGIC, wire[0, 4]
    assert ZstdTcp::Codec.frame_has_dict_id?(wire)
    assert_equal payload, ZstdTcp::Codec.decode_part(wire, frame_codec: recv_codec, no_dict_frame_codec: no_dict_codec)
  end

  it "encodes and validates dictionary shipments" do
    dict = zstd_training_dict
    wire = ZstdTcp::Codec.encode_dict_shipment(dict)

    assert ZstdTcp::Codec.dict_shipment?(wire)
    assert_equal dict, ZstdTcp::Codec.decode_dict_shipment(wire)
    assert_raises(ZstdTcp::ProtocolError) { ZstdTcp::Codec.encode_dict_shipment("raw dictionary".to_slice) }
    assert_raises(ZstdTcp::ProtocolError) do
      ZstdTcp::Codec.encode_dict_shipment(Bytes.new(ZstdTcp::Codec::MAX_DICT_SIZE + 1))
    end
  end

  it "rejects malformed wire parts and missing Frame_Content_Size" do
    recv_codec = Zinc::FrameCodec.new

    assert_raises(ZstdTcp::ProtocolError) do
      ZstdTcp::Codec.decode_part(Bytes[1_u8, 2_u8, 3_u8], frame_codec: recv_codec)
    end
    assert_raises(ZstdTcp::ProtocolError) do
      ZstdTcp::Codec.decode_part(Bytes[1_u8, 2_u8, 3_u8, 4_u8], frame_codec: recv_codec)
    end
    assert_raises(ZstdTcp::ProtocolError) do
      ZstdTcp::Codec.decode_part(ZstdTcp::Codec::ZSTD_MAGIC + Bytes[0_u8, 0_u8], frame_codec: recv_codec)
    end
  end

  it "checks declared decompressed size before invoking the decoder" do
    send_codec = Zinc::FrameCodec.new(level: ZstdTcp::Codec::DEFAULT_LEVEL)
    recv_codec = Zinc::FrameCodec.new
    payload = ("A" * 4096).to_slice
    wire = ZstdTcp::Codec.encode_part(payload, frame_codec: send_codec, min_size: 0)

    assert_raises(ZstdTcp::ProtocolError) do
      ZstdTcp::Codec.decode_part(wire, frame_codec: recv_codec, max_size: 1024_i64)
    end
  end
end
