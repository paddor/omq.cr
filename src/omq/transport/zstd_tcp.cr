require "socket"

module OMQ
  module Transport
    module ZstdTcp
      extend self

      SCHEME = "zstd+tcp"

      class Connection
        getter peer_properties : Hash(String, Bytes)
        getter peer_minor : UInt8
        getter last_wire_size_in : Int32? = nil

        @sender : SendState
        @recv_codec : Zinc::FrameCodec
        @recv_no_dict_codec : Zinc::FrameCodec
        @recv_dict_bytes : Bytes?
        @send_dict_shipped : Bool

        def initialize(
          @inner : ZMTP::Connection,
          *,
          zstd_level : Int32 = Codec::DEFAULT_LEVEL,
          send_dict_bytes : Bytes? = nil,
          @max_message_size : Int64? = nil,
          auto_dict : AutoDict? = nil,
        )
          @sender = SendState.new(zstd_level, dict: send_dict_bytes, auto_dict: auto_dict)
          @recv_no_dict_codec = build_frame_codec(nil)
          @recv_codec = @recv_no_dict_codec
          @recv_dict_bytes = nil
          @send_dict_shipped = false
          @peer_properties = @inner.peer_properties
          @peer_minor = @inner.peer_minor
        end

        def last_received_at : Time::Instant
          @inner.last_received_at
        end

        def touch_last_received : Nil
          @inner.touch_last_received
        end

        def send_ping(ttl_deci : UInt16 = 0_u16, context : Bytes = Bytes.empty) : Nil
          @inner.send_ping(ttl_deci, context)
        end

        def send_command(payload : Bytes) : Nil
          @inner.send_command(payload)
        end

        def send_message(parts : Message) : Nil
          wire = @sender.encode_parts(parts)
          ship_send_dict!
          @inner.send_message(wire)
        end

        def send_messages(messages : Array(Message)) : Nil
          wires = messages.map { |parts| @sender.encode_parts(parts) }
          ship_send_dict!
          @inner.send_messages(wires)
        end

        def receive_message : Message?
          receive_message { |_name, _body| }
        end

        def receive_message(&on_command : String, Bytes -> Nil) : Message?
          loop do
            parts = @inner.receive_message do |name, body|
              on_command.call(name, body)
            end
            return nil unless parts

            decoded = decode_wire_parts(parts)
            if decoded
              @last_wire_size_in = parts.reduce(0) { |sum, part| sum + part.size }
              return decoded
            end
          end
        end

        def close : Nil
          @inner.close
        end

        private def build_frame_codec(dict_bytes : Bytes?) : Zinc::FrameCodec
          if dict = dict_bytes
            Zinc::FrameCodec.new(dict: dict)
          else
            Zinc::FrameCodec.new
          end
        rescue ex : Zinc::Error
          raise ProtocolError.new("ZDICT load failed: #{ex.message}")
        end

        private def ship_send_dict! : Nil
          return if @send_dict_shipped
          dict = @sender.send_dict_bytes
          return unless dict

          @inner.send_message([Codec.encode_dict_shipment(dict)])
          @send_dict_shipped = true
        end

        private def decode_wire_parts(parts : Message) : Message?
          raise ProtocolError.new("empty zstd+tcp message") if parts.empty?

          dict_parts = parts.count { |part| Codec.dict_shipment?(part) }
          if dict_parts > 0
            unless parts.size == 1 && Codec.dict_shipment?(parts[0])
              raise ProtocolError.new("dictionary shipment must be a single-part message")
            end
            install_recv_dict_message!(parts[0])
            return nil
          end

          decoded = Message.new
          budget = @max_message_size
          parts.each do |wire|
            plaintext = Codec.decode_part(
              wire,
              frame_codec: @recv_codec,
              no_dict_frame_codec: @recv_no_dict_codec,
              max_size: budget,
            )
            budget = budget.try { |left| left - plaintext.size }
            decoded << plaintext
          end
          decoded
        end

        private def install_recv_dict_message!(wire : Bytes) : Nil
          if @recv_dict_bytes
            raise ProtocolError.new("second dictionary shipment on the same direction")
          end

          dict_bytes = Codec.decode_dict_shipment(wire)
          @recv_codec = build_frame_codec(dict_bytes)
          @recv_dict_bytes = dict_bytes
        end
      end

      def bind(endpoint : String) : TCP::Listener
        host, port = TCP.parse_authority(endpoint.lchop("#{SCHEME}://"))
        server = TCPServer.new(host, port)
        TCP::Listener.new(server, "#{SCHEME}://#{format_host(host)}:#{server.local_address.port}")
      end

      def connect(endpoint : String) : TCPSocket
        host, port = TCP.parse_authority(endpoint.lchop("#{SCHEME}://"))
        host = "127.0.0.1" if host == "0.0.0.0" || host == "*"
        TCPSocket.new(host, port)
      end

      def adopt(
        tcp : TCPSocket,
        *,
        local_socket_type : String,
        local_identity : Bytes,
        as_server : Bool,
        send_capacity : Int32,
        recv_capacity : Int32,
        mechanism : ZMTP::Mechanism = ZMTP::Mechanism::Null.new,
        max_message_size : Int64? = nil,
        heartbeat_interval : Time::Span? = nil,
        heartbeat_ttl : Time::Span? = nil,
        heartbeat_timeout : Time::Span? = nil,
        sndbuf : Int32? = nil,
        rcvbuf : Int32? = nil,
        zstd_level : Int32 = Codec::DEFAULT_LEVEL,
        zstd_dict : Bytes? = nil,
        auto_dict : AutoDict? = nil,
      ) : Pipe
        tcp.sync = false
        tcp.tcp_nodelay = true
        tcp.send_buffer_size = sndbuf if sndbuf
        tcp.recv_buffer_size = rcvbuf if rcvbuf
        peer_address = TCP.peer_address(tcp)
        raw = ZMTP::Connection.new(tcp, mechanism, wire_frame_limit(max_message_size))
        raw.handshake(
          local_socket_type: local_socket_type,
          local_identity: local_identity,
          as_server: as_server,
          peer_address: peer_address,
        )
        zmtp = Connection.new(
          raw,
          zstd_level: zstd_level,
          send_dict_bytes: zstd_dict,
          max_message_size: max_message_size,
          auto_dict: auto_dict,
        )

        tx = Channel(Message).new(send_capacity)
        rx = Channel(Message).new(recv_capacity)
        commands_tx = Channel(Bytes).new(send_capacity)
        commands_rx = Channel(ZMTP::CommandEvent).new(recv_capacity)
        send_done = Channel(Nil).new
        close_signal = Channel(Nil).new

        spawn write_pump(zmtp, tx, rx, commands_tx, send_done, close_signal)
        spawn read_pump(zmtp, rx, tx, commands_rx, close_signal)
        if (interval = heartbeat_interval) && zmtp.peer_minor >= 1
          spawn Transport.heartbeat_pump(
            zmtp,
            interval: interval,
            ttl: heartbeat_ttl || interval,
            silence_timeout: heartbeat_timeout || interval * 2,
          )
        end

        pipe = Pipe.new(
          tx: tx,
          rx: rx,
          send_done: send_done,
          commands_tx: commands_tx,
          commands_rx: commands_rx,
          close_signal: close_signal,
        )
        pipe.peer_zmtp_minor = zmtp.peer_minor
        pipe.peer_address = peer_address
        if identity = zmtp.peer_properties["Identity"]?
          pipe.peer_identity = identity
        end
        pipe
      end

      private def format_host(host : String) : String
        host.includes?(':') ? "[#{host}]" : host
      end

      private def wire_frame_limit(max_message_size : Int64?) : Int64?
        return nil unless max = max_message_size

        passthrough_bound = safe_add(max, Codec::PASSTHROUGH_ENVELOPE.to_i64)
        dict_bound = Codec::MAX_DICT_SIZE.to_i64
        {passthrough_bound, max, dict_bound}.max
      end

      private def safe_add(*values : Int64) : Int64
        total = 0_i64
        values.each do |value|
          return Int64::MAX if value > Int64::MAX - total
          total += value
        end
        total
      end

      private def write_pump(zmtp : Connection, tx : Channel(Message), rx : Channel(Message), commands_tx : Channel(Bytes), send_done : Channel(Nil), close_signal : Channel(Nil)) : Nil
        batch = Array(Message).new(WRITE_BATCH_MESSAGES)
        loop do
          select
          when msg = tx.receive
            Transport.drain_data_batch(msg, tx, batch)
            zmtp.send_messages(batch)
          when cmd = commands_tx.receive
            zmtp.send_command(cmd)
          end
        end
      rescue Channel::ClosedError | IO::Error | ProtocolError
      ensure
        close_signal.close unless close_signal.closed?
        send_done.close
        tx.close
        rx.close
        commands_tx.close
        zmtp.close
      end

      private def read_pump(
        zmtp : Connection,
        rx : Channel(Message),
        tx : Channel(Message),
        commands_rx : Channel(ZMTP::CommandEvent),
        close_signal : Channel(Nil),
      ) : Nil
        messages_since_yield = 0
        bytes_since_yield = 0
        loop do
          msg = zmtp.receive_message do |name, body|
            begin
              commands_rx.send(ZMTP::CommandEvent.new(name, body))
            rescue Channel::ClosedError
            end
          end
          break unless msg
          begin
            rx.send(msg)
            messages_since_yield += 1
            bytes_since_yield += msg.reduce(0) { |sum, frame| sum + frame.size }
            if messages_since_yield >= RECV_FAIRNESS_MESSAGES || bytes_since_yield >= RECV_FAIRNESS_BYTES
              messages_since_yield = 0
              bytes_since_yield = 0
              Fiber.yield
            end
          rescue Channel::ClosedError
            break
          end
        end
      rescue IO::Error | ProtocolError
      ensure
        close_signal.close unless close_signal.closed?
        rx.close
        tx.close
        commands_rx.close unless commands_rx.closed?
        zmtp.close
      end
    end
  end
end
