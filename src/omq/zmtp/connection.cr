module OMQ::ZMTP
  # Wraps a byte-stream `IO` and exposes message-level send/receive once
  # the greeting + mechanism handshake has completed.
  class Connection
    getter peer_properties : Hash(String, Bytes) = {} of String => Bytes

    def initialize(
      @io : IO,
      @mechanism : Mechanism = Mechanism::Null.new,
      @max_message_size : Int64? = nil,
    )
    end

    # Drive the greeting exchange and mechanism handshake. Raises
    # `UnsupportedVersion` for ZMTP 2.x peers and `ProtocolError` for
    # bad signatures / mechanism mismatches.
    def handshake(*, local_socket_type : String, local_identity : Bytes, as_server : Bool) : Nil
      Greeting.new(@mechanism.name, as_server: as_server).to_io(@io)
      flush

      remote = Greeting.from_io(@io)
      unless remote.mechanism == @mechanism.name
        raise ProtocolError.new(
          "mechanism mismatch: local=#{@mechanism.name} remote=#{remote.mechanism}"
        )
      end

      @peer_properties = @mechanism.handshake(
        @io,
        local_socket_type: local_socket_type,
        local_identity: local_identity,
        as_server: as_server,
      )
    end

    # Send one multipart message.
    def send_message(parts : Message) : Nil
      last = parts.size - 1
      parts.each_with_index do |part, i|
        Frame.encode(@io, part, more: i < last)
      end
      flush
    end

    # Read one multipart message. Returns nil on clean EOF.
    def receive_message : Message?
      parts = Message.new
      loop do
        flags_byte = @io.read_byte
        return nil if flags_byte.nil? && parts.empty?
        raise ProtocolError.new("connection closed mid-message") if flags_byte.nil?

        flags = flags_byte
        more = (flags & FLAG_MORE) != 0
        long = (flags & FLAG_LONG) != 0
        command = (flags & FLAG_COMMAND) != 0
        size = if long
                 @io.read_bytes(UInt64, IO::ByteFormat::NetworkEndian).to_i64
               else
                 (@io.read_byte || raise ProtocolError.new("truncated frame")).to_i64
               end
        if max = @max_message_size
          raise ProtocolError.new("frame too large: #{size} > #{max}") if size > max
        end
        payload = Bytes.new(size)
        @io.read_fully(payload) if size > 0

        # Commands are handled transparently (PING/PONG); pass others up.
        if command
          handle_command(payload)
          next
        end

        parts << payload
        break unless more
      end
      parts
    end

    def close : Nil
      @io.close
    rescue
      # closing a closed IO is harmless
    end

    private def handle_command(payload : Bytes) : Nil
      name, body = Command.parse(payload)
      case name
      when "PING"
        _ttl, ctx = Command.parse_ping(body)
        pong = Command.pong(ctx)
        Frame.encode(@io, pong, command: true)
        flush
      when "PONG"
        # ignored; heartbeat logic owns the timing
      else
        # SUBSCRIBE/CANCEL/JOIN/LEAVE bubble up via the engine, not here
        raise ProtocolError.new("unhandled in-band command: #{name}")
      end
    end

    private def flush : Nil
      @io.flush if @io.responds_to?(:flush)
    end
  end
end
