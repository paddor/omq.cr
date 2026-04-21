module OMQ::ZMTP
  # ZMTP commands. A command is carried in a COMMAND-flagged frame.
  # Layout inside the frame payload:
  #   name-length (1 byte) + name (ASCII) + command-specific body
  module Command
    extend self

    # READY: socket type + identity (and any extra properties).
    # Properties: name-length (1 byte) + name + value-length (4 bytes BE) + value.
    def ready(socket_type : String, identity : Bytes = Bytes.empty, extras : Hash(String, Bytes)? = nil) : Bytes
      io = IO::Memory.new
      write_name(io, "READY")
      write_property(io, "Socket-Type", socket_type.to_slice)
      write_property(io, "Identity", identity)
      extras.try &.each do |k, v|
        write_property(io, k, v)
      end
      io.to_slice
    end

    def subscribe(prefix : Bytes) : Bytes
      name_body("SUBSCRIBE", prefix)
    end

    def cancel(prefix : Bytes) : Bytes
      name_body("CANCEL", prefix)
    end

    def join(group : String) : Bytes
      name_body("JOIN", group.to_slice)
    end

    def leave(group : String) : Bytes
      name_body("LEAVE", group.to_slice)
    end

    # PING: TTL (uint16 BE, deciseconds) + context (up to 16 bytes).
    def ping(ttl_deci : UInt16, context : Bytes = Bytes.empty) : Bytes
      io = IO::Memory.new
      write_name(io, "PING")
      io.write_bytes(ttl_deci, IO::ByteFormat::NetworkEndian)
      io.write(context)
      io.to_slice
    end

    def pong(context : Bytes = Bytes.empty) : Bytes
      name_body("PONG", context)
    end

    # Parse a command frame payload: returns `{name, rest}`.
    def parse(payload : Bytes) : {String, Bytes}
      raise ProtocolError.new("empty command frame") if payload.empty?
      name_len = payload[0].to_i
      raise ProtocolError.new("truncated command name") if payload.size < 1 + name_len
      name = String.new(payload[1, name_len])
      rest = payload[1 + name_len..]
      {name, rest}
    end

    # Parse READY's property list into a hash.
    def parse_properties(body : Bytes) : Hash(String, Bytes)
      props = {} of String => Bytes
      io = IO::Memory.new(body)
      while io.pos < body.size
        name_len = io.read_byte || break
        name_bytes = Bytes.new(name_len.to_i)
        io.read_fully(name_bytes)
        value_len = io.read_bytes(UInt32, IO::ByteFormat::NetworkEndian)
        value = Bytes.new(value_len.to_i)
        io.read_fully(value)
        props[String.new(name_bytes)] = value
      end
      props
    end

    # Parse PING: returns `{ttl_deci, context}`.
    def parse_ping(body : Bytes) : {UInt16, Bytes}
      raise ProtocolError.new("PING body too short") if body.size < 2
      ttl = IO::ByteFormat::NetworkEndian.decode(UInt16, body[0, 2])
      {ttl, body[2..]}
    end

    private def name_body(name : String, body : Bytes) : Bytes
      io = IO::Memory.new
      write_name(io, name)
      io.write(body)
      io.to_slice
    end

    private def write_name(io : IO, name : String) : Nil
      bytes = name.to_slice
      raise ProtocolError.new("command name too long: #{name}") if bytes.size > 255
      io.write_byte(bytes.size.to_u8)
      io.write(bytes)
    end

    private def write_property(io : IO, name : String, value : Bytes) : Nil
      name_bytes = name.to_slice
      raise ProtocolError.new("property name too long") if name_bytes.size > 255
      io.write_byte(name_bytes.size.to_u8)
      io.write(name_bytes)
      io.write_bytes(value.size.to_u32, IO::ByteFormat::NetworkEndian)
      io.write(value) if value.size > 0
    end
  end
end
