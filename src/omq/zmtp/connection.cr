module OMQ::ZMTP
  # Wraps a byte-stream `IO` and exposes message-level send/receive once
  # the greeting + mechanism handshake has completed.
  class Connection
    getter peer_properties : Hash(String, Bytes) = {} of String => Bytes

    # ZMTP minor version the peer advertised in its greeting.
    # 0 = ZMTP 3.0 (legacy subscribe as data frames, no PING/PONG),
    # 1 = ZMTP 3.1 (SUBSCRIBE/CANCEL commands, PING/PONG).
    # Set during #handshake; meaningless before.
    getter peer_minor : UInt8 = MINOR_VERSION

    # Wall-clock instant of the most recent successful wire-level read.
    # Used by heartbeat pumps to decide when the peer has gone silent.
    getter last_received_at : Time::Instant = Time.instant

    # Reset the silence baseline. Heartbeat pumps call this at startup so
    # handshake latency doesn't eat into the first silence window.
    def touch_last_received : Nil
      @last_received_at = Time.instant
    end

    @write_mutex = Mutex.new

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
      @peer_minor = remote.minor
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
      @write_mutex.synchronize do
        last = parts.size - 1
        parts.each_with_index do |part, i|
          Frame.encode(@io, part, more: i < last)
        end
        flush
      end
    end

    # Fire-and-forget PING command. Peers are expected to respond with
    # PONG; the reply bumps `last_received_at` via the normal read path.
    def send_ping(ttl_deci : UInt16 = 0_u16, context : Bytes = Bytes.empty) : Nil
      ping = Command.ping(ttl_deci, context)
      @write_mutex.synchronize do
        Frame.encode(@io, ping, command: true)
        flush
      end
    end

    # Send a pre-encoded ZMTP command payload (name-length + name + body).
    # Used by SUB for SUBSCRIBE/CANCEL.
    def send_command(payload : Bytes) : Nil
      @write_mutex.synchronize do
        Frame.encode(@io, payload, command: true)
        flush
      end
    end

    # Read one multipart message. Returns nil on clean EOF.
    def receive_message : Message?
      parts = Message.new
      loop do
        flags_byte = @io.read_byte
        return nil if flags_byte.nil? && parts.empty?
        raise ProtocolError.new("connection closed mid-message") if flags_byte.nil?
        @last_received_at = Time.instant

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
        @write_mutex.synchronize do
          Frame.encode(@io, pong, command: true)
          flush
        end
      when "PONG"
        # ignored; heartbeat logic owns the timing
      when "SUBSCRIBE", "CANCEL"
        # v0.1 PUB broadcasts everything and filters on the SUB side, so
        # these are silent no-ops. Keeps interop with libzmq/ruby-omq
        # SUBs that send real wire-level subscribe commands.
      when "JOIN", "LEAVE"
        # v0.1 RADIO broadcasts everything and filters on the DISH side,
        # so JOIN/LEAVE are silent no-ops (same pattern as SUBSCRIBE).
      else
        raise ProtocolError.new("unhandled in-band command: #{name}")
      end
    end

    private def flush : Nil
      @io.flush if @io.responds_to?(:flush)
    end
  end
end
