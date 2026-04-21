require "../../test_helper"

describe "OMQ::ZMTP::Frame" do
  it "round-trips a short frame" do
    io = IO::Memory.new
    OMQ::ZMTP::Frame.encode(io, "hello".to_slice)
    io.rewind
    payload, more, command = OMQ::ZMTP::Frame.decode(io)
    assert_equal "hello", String.new(payload)
    refute more
    refute command
  end

  it "uses 1-byte length for payloads <= 255 bytes" do
    io = IO::Memory.new
    OMQ::ZMTP::Frame.encode(io, Bytes.new(255, 0xAB_u8))
    # flags(1) + len(1) + payload(255) = 257
    assert_equal 257, io.size
  end

  it "switches to 8-byte length for payloads > 255 bytes" do
    io = IO::Memory.new
    OMQ::ZMTP::Frame.encode(io, Bytes.new(256, 0xAB_u8))
    # flags(1) + len(8) + payload(256) = 265
    assert_equal 265, io.size
    io.rewind
    flags = io.read_byte.not_nil!
    assert_equal 0x02_u8, flags & OMQ::ZMTP::FLAG_LONG
  end

  it "encodes MORE and COMMAND flags" do
    io = IO::Memory.new
    OMQ::ZMTP::Frame.encode(io, "x".to_slice, more: true, command: true)
    io.rewind
    flags = io.read_byte.not_nil!
    assert_equal 0x05_u8, flags & (OMQ::ZMTP::FLAG_MORE | OMQ::ZMTP::FLAG_COMMAND)
    _, more, command = OMQ::ZMTP::Frame.decode(IO::Memory.new(io.to_slice))
    assert more
    assert command
  end

  it "round-trips a multipart message" do
    parts = ["a".to_slice, "bb".to_slice, "ccc".to_slice]
    wire = OMQ::ZMTP::Frame.encode_message(parts)
    decoded = OMQ::ZMTP::Frame.decode_message(IO::Memory.new(wire))
    assert_equal parts.size, decoded.size
    assert_equal "a", String.new(decoded[0])
    assert_equal "bb", String.new(decoded[1])
    assert_equal "ccc", String.new(decoded[2])
  end

  it "rejects frames larger than max_size" do
    io = IO::Memory.new
    OMQ::ZMTP::Frame.encode(io, Bytes.new(1024, 0))
    io.rewind
    assert_raises(OMQ::ProtocolError) do
      OMQ::ZMTP::Frame.decode(io, max_size: 512_i64)
    end
  end

  it "raises on short read" do
    io = IO::Memory.new(Bytes[0x00])   # flags but no length byte
    assert_raises(IO::EOFError) { OMQ::ZMTP::Frame.decode(io) }
  end

  it "encodes an empty payload" do
    io = IO::Memory.new
    OMQ::ZMTP::Frame.encode(io, Bytes.empty)
    io.rewind
    payload, _, _ = OMQ::ZMTP::Frame.decode(io)
    assert_equal 0, payload.size
  end
end
