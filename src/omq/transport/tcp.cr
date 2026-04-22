require "socket"

module OMQ
  module Transport
    # TCP transport: plain `TCPServer` / `TCPSocket`, wrapped in a
    # `ZMTP::Connection`. Pumps bridge the wire-level connection to a
    # `Pipe` so the socket code is transport-agnostic.
    module TCP
      extend self

      # Parse `host:port` from the authority part of a `tcp://` URI.
      # Accepts `127.0.0.1:5555`, `[::1]:5555`, `*:0`, `localhost:1234`.
      def parse_authority(rest : String) : {String, Int32}
        host, _, port_s = rest.rpartition(':')
        raise InvalidEndpoint.new("tcp://#{rest}: missing port") if port_s.empty?
        port = port_s.to_i? || raise InvalidEndpoint.new("tcp://#{rest}: bad port")
        host = host.lchop('[').rchop(']') if host.starts_with?('[')
        host = "0.0.0.0" if host.empty? || host == "*"
        {host, port}
      end

      class Listener
        getter server : TCPServer
        getter endpoint : String
        getter port : Int32

        def initialize(@server : TCPServer, @endpoint : String)
          @port = @server.local_address.port
        end

        def accept : TCPSocket?
          @server.accept?
        end

        def close : Nil
          @server.close unless @server.closed?
        end
      end

      def bind(endpoint : String) : Listener
        host, port = parse_authority(endpoint.lchop("tcp://"))
        server = TCPServer.new(host, port)
        Listener.new(server, endpoint)
      end

      def connect(endpoint : String) : TCPSocket
        host, port = parse_authority(endpoint.lchop("tcp://"))
        host = "127.0.0.1" if host == "0.0.0.0" || host == "*"
        TCPSocket.new(host, port)
      end

      # Handshake a TCP socket, spawn read + write pump fibers, and
      # expose the result as a `Pipe`. Closing either channel end or the
      # socket tears all three down.
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
      ) : Pipe
        tcp.sync = false
        # Match libzmq/JeroMQ: disable Nagle so multi-write messages (frame
        # header + payload as two buffered writes) don't stall on the
        # delayed-ACK timer. Round-trip latency for ≥ ~32 KiB messages goes
        # from ~90 ms to ~1 ms with NODELAY.
        tcp.tcp_nodelay = true
        tcp.send_buffer_size = sndbuf if sndbuf
        tcp.recv_buffer_size = rcvbuf if rcvbuf
        zmtp = ZMTP::Connection.new(tcp, mechanism, max_message_size)
        zmtp.handshake(
          local_socket_type: local_socket_type,
          local_identity: local_identity,
          as_server: as_server,
        )

        tx          = Channel(Message).new(send_capacity)
        rx          = Channel(Message).new(recv_capacity)
        commands_tx = Channel(Bytes).new(send_capacity)
        send_done   = Channel(Nil).new

        spawn write_pump(zmtp, tx, rx, commands_tx, send_done)
        spawn read_pump(zmtp, rx, tx)
        # PING/PONG is a ZMTP 3.1 addition; 3.0 peers would error on an
        # unknown command. Skip heartbeats against them.
        if (interval = heartbeat_interval) && zmtp.peer_minor >= 1
          spawn Transport.heartbeat_pump(
            zmtp,
            interval: interval,
            ttl: heartbeat_ttl || interval,
            silence_timeout: heartbeat_timeout || interval * 2,
          )
        end

        pipe = Pipe.new(tx: tx, rx: rx, send_done: send_done, commands_tx: commands_tx)
        pipe.peer_zmtp_minor = zmtp.peer_minor
        if identity = zmtp.peer_properties["Identity"]?
          pipe.peer_identity = identity
        end
        pipe
      end

      # Drain `tx` and `commands_tx` and write each to the wire. Closes
      # `send_done` on exit so `Pipe#await_drained` can observe when the
      # outgoing queue has been fully flushed (or the wire has gone away).
      private def write_pump(zmtp : ZMTP::Connection, tx : Channel(Message), rx : Channel(Message), commands_tx : Channel(Bytes), send_done : Channel(Nil)) : Nil
        loop do
          select
          when msg = tx.receive
            zmtp.send_message(msg)
          when cmd = commands_tx.receive
            zmtp.send_command(cmd)
          end
        end
      rescue Channel::ClosedError | IO::Error | ProtocolError
        # one side closed or peer gone — tear down
      ensure
        send_done.close
        tx.close
        rx.close
        commands_tx.close
        zmtp.close
      end

      # Read messages from the wire and push them to `rx`.
      private def read_pump(zmtp : ZMTP::Connection, rx : Channel(Message), tx : Channel(Message)) : Nil
        loop do
          msg = zmtp.receive_message
          break unless msg
          begin
            rx.send(msg)
          rescue Channel::ClosedError
            break
          end
        end
      rescue IO::Error | ProtocolError
        # peer gone
      ensure
        rx.close
        tx.close
        zmtp.close
      end
    end
  end
end
