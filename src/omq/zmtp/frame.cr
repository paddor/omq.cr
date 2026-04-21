module OMQ::ZMTP
  # ZMTP 3.1 frame codec. A frame is a flags byte + a length + a payload.
  #
  # flags layout (3 bits used):
  #   0x01 MORE    — more frames follow in this message
  #   0x02 LONG    — 8-byte length field (vs 1 byte)
  #   0x04 COMMAND — frame is a command, not message data
  module Frame
    extend self

    # Encode `payload` as a single frame onto `io`.
    def encode(io : IO, payload : Bytes, *, more : Bool = false, command : Bool = false) : Nil
      size = payload.size
      long = size > 255
      flags = 0_u8
      flags |= FLAG_MORE if more
      flags |= FLAG_LONG if long
      flags |= FLAG_COMMAND if command
      io.write_byte(flags)
      if long
        io.write_bytes(size.to_u64, IO::ByteFormat::NetworkEndian)
      else
        io.write_byte(size.to_u8)
      end
      io.write(payload) if size > 0
    end

    # Decode one frame. Returns `{payload, more?, command?}`.
    # Raises `IO::EOFError` on short read.
    def decode(io : IO, max_size : Int64? = nil) : {Bytes, Bool, Bool}
      flags = io.read_byte || raise IO::EOFError.new
      more = (flags & FLAG_MORE) != 0
      command = (flags & FLAG_COMMAND) != 0
      long = (flags & FLAG_LONG) != 0
      size = if long
               io.read_bytes(UInt64, IO::ByteFormat::NetworkEndian).to_i64
             else
               (io.read_byte || raise IO::EOFError.new).to_i64
             end
      if max = max_size
        raise ProtocolError.new("frame too large: #{size} > #{max}") if size > max
      end
      payload = Bytes.new(size)
      io.read_fully(payload) if size > 0
      {payload, more, command}
    end

    # Encode a full message as a sequence of MORE-flagged frames.
    # Returns the complete wire bytes as a frozen `Bytes` — useful for
    # fan-out where the same bytes ship to many peers.
    def encode_message(parts : Message) : Bytes
      io = IO::Memory.new
      last = parts.size - 1
      parts.each_with_index do |part, i|
        encode(io, part, more: i < last)
      end
      io.to_slice
    end

    # Read one full multi-part message (reads frames until !more).
    def decode_message(io : IO, max_size : Int64? = nil) : Message
      parts = Message.new
      loop do
        payload, more, command = decode(io, max_size)
        raise ProtocolError.new("unexpected COMMAND frame in message") if command
        parts << payload
        break unless more
      end
      parts
    end
  end
end
