require "socket"

module OMQ
  module Transport
    # IPC transport: UNIX-domain sockets, wrapped in a `ZMTP::Connection`
    # the same way as TCP. A leading `@` selects Linux's abstract
    # namespace (the socket lives in kernel memory, no filesystem entry);
    # everything else is treated as a filesystem path.
    module IPC
      extend self

      # Strip the `ipc://` scheme and return the remaining path. `@foo`
      # is the abstract namespace form; anything else is a filesystem path.
      def parse_path(endpoint : String) : String
        raise InvalidEndpoint.new("expected ipc://: #{endpoint}") unless endpoint.starts_with?("ipc://")
        endpoint[6..]
      end

      def abstract?(path : String) : Bool
        path.starts_with?("@")
      end

      # Turn our friendly `@name` into the `\0name` the kernel expects.
      def to_socket_path(path : String) : String
        return path unless abstract?(path)
        String.build do |io|
          io.write_byte(0_u8)
          io << path[1..]
        end
      end

      class Listener
        getter server : UNIXServer
        getter endpoint : String
        getter path : String
        getter? abstract : Bool

        def initialize(@server : UNIXServer, @endpoint : String, @path : String)
          @abstract = IPC.abstract?(@path)
        end

        def accept : UNIXSocket?
          @server.accept?
        end

        def close : Nil
          return if @server.closed?
          # Abstract sockets have no filesystem entry — tell UNIXServer not
          # to try to delete one. Filesystem paths get cleaned up.
          @server.close(delete: !@abstract)
        end
      end

      def bind(endpoint : String) : Listener
        path = parse_path(endpoint)
        sock_path = to_socket_path(path)
        if !abstract?(path) && File.exists?(sock_path)
          File.delete(sock_path)
        end
        server = UNIXServer.new(sock_path)
        Listener.new(server, endpoint, path)
      end

      def connect(endpoint : String) : UNIXSocket
        path = parse_path(endpoint)
        UNIXSocket.new(to_socket_path(path))
      end

      # Handshake + pump fibers, mirroring Transport::TCP.adopt.
      def adopt(
        sock : UNIXSocket,
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
        sock.sync = false
        sock.send_buffer_size = sndbuf if sndbuf
        sock.recv_buffer_size = rcvbuf if rcvbuf
        zmtp = ZMTP::Connection.new(sock, mechanism, max_message_size)
        zmtp.handshake(
          local_socket_type: local_socket_type,
          local_identity: local_identity,
          as_server: as_server,
        )

        tx = Channel(Message).new(send_capacity)
        rx = Channel(Message).new(recv_capacity)
        send_done = Channel(Nil).new

        spawn write_pump(zmtp, tx, rx, send_done)
        spawn read_pump(zmtp, rx, tx)
        if interval = heartbeat_interval
          spawn Transport.heartbeat_pump(
            zmtp,
            interval: interval,
            ttl: heartbeat_ttl || interval,
            silence_timeout: heartbeat_timeout || interval * 2,
          )
        end

        pipe = Pipe.new(tx: tx, rx: rx, send_done: send_done)
        if identity = zmtp.peer_properties["Identity"]?
          pipe.peer_identity = identity
        end
        pipe
      end

      private def write_pump(zmtp : ZMTP::Connection, tx : Channel(Message), rx : Channel(Message), send_done : Channel(Nil)) : Nil
        while msg = tx.receive?
          zmtp.send_message(msg)
        end
      rescue IO::Error | ProtocolError
        # peer gone
      ensure
        send_done.close
        tx.close
        rx.close
        zmtp.close
      end

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
