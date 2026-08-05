require "socket"

module OMQ
  module Transport
    # UDP transport for RADIO/DISH. No ZMTP handshake; every datagram is
    # `flags(0x01) | group-size | group | body`.
    module UDP
      extend self

      MAX_DATAGRAM_SIZE =  65_507
      FLAG_DATA         = 0x01_u8

      def parse_authority(rest : String) : {String?, String, Int32}
        group = nil
        authority = rest
        if at = rest.rindex('@')
          group = rest[0...at]
          authority = rest[(at + 1)..]
        end

        host, port = Transport::TCP.parse_authority(authority)
        {group, host, port}
      end

      def encode_datagram(group : Bytes, body : Bytes) : Bytes
        raise ProtocolError.new("RADIO group name too long (#{group.size} bytes; max 255)") if group.size > 255
        raise ProtocolError.new("UDP datagram too large") if 2 + group.size + body.size > MAX_DATAGRAM_SIZE

        output = Bytes.new(2 + group.size + body.size)
        output[0] = FLAG_DATA
        output[1] = group.size.to_u8
        output[2, group.size].copy_from(group) if group.size > 0
        output[2 + group.size, body.size].copy_from(body) if body.size > 0
        output
      end

      def decode_datagram(data : Bytes) : Message?
        return nil if data.size < 2
        return nil unless data[0] == FLAG_DATA

        group_size = data[1].to_i
        return nil if data.size < 2 + group_size

        group = data[2, group_size].dup
        body = data[2 + group_size, data.size - 2 - group_size].dup
        Message{group, body}
      end

      class Listener
        getter socket : UDPSocket
        getter endpoint : String
        getter port : Int32

        def initialize(@socket : UDPSocket, @endpoint : String)
          @port = @socket.local_address.port
        end

        def close : Nil
          @socket.close unless @socket.closed?
        end
      end

      def bind(endpoint : String) : Listener
        _group, host, port = parse_authority(endpoint.lchop("udp://"))
        host = "0.0.0.0" if host.empty? || host == "*"

        socket = UDPSocket.new(host.includes?(':') ? ::Socket::Family::INET6 : ::Socket::Family::INET)
        socket.bind(host, port)
        Listener.new(socket, "udp://#{format_host(host)}:#{socket.local_address.port}")
      end

      private def format_host(host : String) : String
        host.includes?(':') ? "[#{host}]" : host
      end

      def connect(endpoint : String) : UDPSocket
        _group, host, port = parse_authority(endpoint.lchop("udp://"))
        raise InvalidEndpoint.new("udp connect cannot target wildcard host") if host.empty? || host == "*" || host == "0.0.0.0"

        socket = UDPSocket.new(host.includes?(':') ? ::Socket::Family::INET6 : ::Socket::Family::INET)
        socket.connect(host, port)
        socket
      end

      def adopt_sender(socket : UDPSocket, *, send_capacity : Int32, recv_capacity : Int32) : Pipe
        tx = Channel(Message).new(send_capacity)
        rx = Channel(Message).new(recv_capacity)
        send_done = Channel(Nil).new
        close_signal = Channel(Nil).new

        spawn write_pump(socket, tx, rx, send_done, close_signal)

        pipe = Pipe.new(tx: tx, rx: rx, send_done: send_done, close_signal: close_signal)
        pipe.radio_broadcast_all = true
        pipe
      end

      def adopt_receiver(socket : UDPSocket, *, send_capacity : Int32, recv_capacity : Int32) : Pipe
        tx = Channel(Message).new(send_capacity)
        rx = Channel(Message).new(recv_capacity)
        send_done = Channel(Nil).new
        close_signal = Channel(Nil).new
        send_done.close

        spawn read_pump(socket, tx, rx, close_signal)

        Pipe.new(tx: tx, rx: rx, send_done: send_done, close_signal: close_signal)
      end

      private def write_pump(socket : UDPSocket, tx : Channel(Message), rx : Channel(Message), send_done : Channel(Nil), close_signal : Channel(Nil)) : Nil
        while msg = tx.receive?
          next if msg.size < 2
          datagram = encode_datagram(msg[0], msg[1])
          written = socket.send(datagram)
          raise IO::Error.new("short UDP send") unless written == datagram.size
        end
      rescue Channel::ClosedError | IO::Error | ::Socket::Error | ProtocolError
      ensure
        close_signal.close unless close_signal.closed?
        send_done.close unless send_done.closed?
        tx.close unless tx.closed?
        rx.close unless rx.closed?
        socket.close unless socket.closed?
      end

      private def read_pump(socket : UDPSocket, tx : Channel(Message), rx : Channel(Message), close_signal : Channel(Nil)) : Nil
        buffer = Bytes.new(MAX_DATAGRAM_SIZE)
        loop do
          size, _addr = socket.receive(buffer)
          if msg = decode_datagram(buffer[0, size])
            rx.send(msg)
          end
        end
      rescue Channel::ClosedError | IO::Error | ::Socket::Error
      ensure
        close_signal.close unless close_signal.closed?
        tx.close unless tx.closed?
        rx.close unless rx.closed?
        socket.close unless socket.closed?
      end
    end
  end
end
