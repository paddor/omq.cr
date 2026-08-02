require "../test_helper"

private alias Lz4Tcp = OMQ::Transport::Lz4Tcp

private def patterned_bytes(size : Int32) : Bytes
  Bytes.new(size) { |i| ((i * 31 + size) % 251).to_u8 }
end

describe "Lz4Tcp::Codec" do
  it "round-trips small and large parts" do
    codec = Flint::BlockCodec.new

    [0, 1, 64, 512, 4096, 65_536].each do |size|
      payload = patterned_bytes(size)
      wire = Lz4Tcp::Codec.encode_part(payload, block_codec: codec, min_size: 0)

      assert_equal payload, Lz4Tcp::Codec.decode_part(wire, block_codec: codec)
    end
  end

  it "passes through payloads below the compression threshold" do
    codec = Flint::BlockCodec.new
    wire = Lz4Tcp::Codec.encode_part("hello".to_slice, block_codec: codec)

    assert_equal Lz4Tcp::Codec::UNCOMPRESSED_SENTINEL, wire[0, 4]
    assert_equal "hello", String.new(Lz4Tcp::Codec.decode_part(wire, block_codec: codec))
  end

  it "uses LZ4B for compressible payloads above the threshold" do
    codec = Flint::BlockCodec.new
    payload = ("A" * 4096).to_slice
    wire = Lz4Tcp::Codec.encode_part(payload, block_codec: codec)

    assert_equal Lz4Tcp::Codec::LZ4B_SENTINEL, wire[0, 4]
    assert_equal payload, Lz4Tcp::Codec.decode_part(wire, block_codec: codec)
  end

  it "uses LZ4M when a part exceeds the block size" do
    codec = Flint::BlockCodec.new
    payload = ("A" * 700).to_slice
    wire = Lz4Tcp::Codec.encode_part(payload, block_codec: codec, min_size: 0, block_size: 256)

    assert_equal Lz4Tcp::Codec::LZ4M_SENTINEL, wire[0, 4]
    assert_equal payload, Lz4Tcp::Codec.decode_part(wire, block_codec: codec, block_size: 256)
  end

  it "round-trips with a dictionary codec" do
    dict = ("event=login user=alice payload=" * 8).to_slice
    codec = Flint::BlockCodec.new(dict: dict)
    payload = ("event=login user=alice payload=" * 12).to_slice

    wire = Lz4Tcp::Codec.encode_part(payload, block_codec: codec, min_size: 0)

    assert_equal payload, Lz4Tcp::Codec.decode_part(wire, block_codec: codec)
  end

  it "encodes and validates dictionary shipments" do
    dict = ("common prefix " * 8).to_slice
    wire = Lz4Tcp::Codec.encode_dict_shipment(dict)

    assert Lz4Tcp::Codec.dict_shipment?(wire)
    assert_equal dict, Lz4Tcp::Codec.decode_dict_shipment(wire)
    assert_raises(Lz4Tcp::ProtocolError) { Lz4Tcp::Codec.encode_dict_shipment(Bytes.empty) }
    assert_raises(Lz4Tcp::ProtocolError) do
      Lz4Tcp::Codec.encode_dict_shipment(Bytes.new(Lz4Tcp::Codec::MAX_DICT_SIZE + 1))
    end
  end

  it "rejects malformed wire parts" do
    codec = Flint::BlockCodec.new

    assert_raises(Lz4Tcp::ProtocolError) do
      Lz4Tcp::Codec.decode_part(Bytes[1_u8, 2_u8, 3_u8], block_codec: codec)
    end
    assert_raises(Lz4Tcp::ProtocolError) do
      Lz4Tcp::Codec.decode_part(Bytes[1_u8, 2_u8, 3_u8, 4_u8], block_codec: codec)
    end
    assert_raises(Lz4Tcp::ProtocolError) do
      Lz4Tcp::Codec.decode_part(Lz4Tcp::Codec::LZ4B_SENTINEL + Bytes[0_u8], block_codec: codec)
    end
  end

  it "checks decoded size before invoking the LZ4 decoder" do
    codec = Flint::BlockCodec.new
    payload = ("A" * 4096).to_slice
    wire = Lz4Tcp::Codec.encode_part(payload, block_codec: codec, min_size: 0)

    assert_raises(Lz4Tcp::ProtocolError) do
      Lz4Tcp::Codec.decode_part(wire, block_codec: codec, max_size: 1024_i64)
    end
  end
end
