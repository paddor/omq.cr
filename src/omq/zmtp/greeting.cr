module OMQ::ZMTP
  # 64-byte ZMTP greeting.
  #
  #   0..9    signature   [0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0x7F]
  #   10      major       3
  #   11      minor       1
  #   12..31  mechanism   20-byte ASCII, null-padded (e.g. "NULL")
  #   32      as_server   0 | 1
  #   33..63  filler      31 zero bytes
  struct Greeting
    getter major : UInt8
    getter minor : UInt8
    getter mechanism : String
    getter? as_server : Bool

    def initialize(@major : UInt8, @minor : UInt8, @mechanism : String, @as_server : Bool)
    end

    def self.new(mechanism : String, *, as_server : Bool)
      new(MAJOR_VERSION, MINOR_VERSION, mechanism, as_server)
    end

    # Write the full 64-byte greeting to `io`.
    def to_io(io : IO) : Nil
      io.write(SIGNATURE)
      io.write_byte(@major)
      io.write_byte(@minor)
      mech_field = Bytes.new(20)
      name = @mechanism.to_slice
      raise ProtocolError.new("mechanism name too long") if name.size > 20
      name.copy_to(mech_field)
      io.write(mech_field)
      io.write_byte(@as_server ? 1_u8 : 0_u8)
      io.write(Bytes.new(31))
    end

    # Two-stage read: first 11 bytes (signature + major) are read eagerly so
    # we can reject ZMTP 2.0 (major=1) before the peer sends the rest.
    def self.from_io(io : IO) : Greeting
      sig_and_major = Bytes.new(11)
      io.read_fully(sig_and_major)
      validate_signature!(sig_and_major)
      major = sig_and_major[10]
      raise UnsupportedVersion.new(
        "ZMTP #{major}.x peer not supported (only 3.x)"
      ) if major < MIN_ACCEPTED_MAJOR

      rest = Bytes.new(GREETING_SIZE - 11)
      io.read_fully(rest)
      minor = rest[0]
      mech_bytes = rest[1, 20]
      mech_end = mech_bytes.index(0_u8) || 20
      mechanism = String.new(mech_bytes[0, mech_end])
      as_server = rest[21] != 0_u8
      Greeting.new(major, minor, mechanism, as_server)
    end

    private def self.validate_signature!(prefix : Bytes) : Nil
      10.times do |i|
        if prefix[i] != SIGNATURE[i]
          raise ProtocolError.new("bad ZMTP greeting signature at byte #{i}")
        end
      end
    end
  end
end
