module OMQ
  module Transport
    # Raw TCP driver for STREAM sockets. No ZMTP greeting and no frame
    # encoding: inbound TCP bytes become `[identity, bytes]`, outbound
    # messages write their first frame as raw bytes. Empty outbound data
    # closes the connection.
    module StreamRaw
      extend self

      BUFFER_SIZE = 64 * 1024

      def adopt(
        tcp : TCPSocket,
        *,
        send_capacity : Int32,
        recv_capacity : Int32,
        sndbuf : Int32? = nil,
        rcvbuf : Int32? = nil,
      ) : Pipe
        tcp.sync = false
        tcp.tcp_nodelay = true
        tcp.send_buffer_size = sndbuf if sndbuf
        tcp.recv_buffer_size = rcvbuf if rcvbuf

        tx = Channel(Message).new(send_capacity)
        rx = Channel(Message).new(recv_capacity)
        send_done = Channel(Nil).new
        close_signal = Channel(Nil).new
        identity = Random::Secure.random_bytes(5)
        disconnect_sent = Atomic(Bool).new(false)

        spawn read_pump(tcp, identity, rx, tx, close_signal, disconnect_sent)
        spawn write_pump(tcp, identity, tx, rx, send_done, close_signal, disconnect_sent)

        pipe = Pipe.new(
          tx: tx,
          rx: rx,
          send_done: send_done,
          close_signal: close_signal,
        )
        pipe.peer_identity = identity
        pipe.peer_address = TCP.peer_address(tcp)
        pipe
      end

      private def read_pump(
        tcp : TCPSocket,
        identity : Bytes,
        rx : Channel(Message),
        tx : Channel(Message),
        close_signal : Channel(Nil),
        disconnect_sent : Atomic(Bool),
      ) : Nil
        notify(rx, identity, Bytes.empty)
        buf = Bytes.new(BUFFER_SIZE)
        messages_since_yield = 0
        bytes_since_yield = 0

        loop do
          n = tcp.read(buf)
          break if n <= 0
          data = Bytes.new(n)
          data.copy_from(buf[0, n])
          notify(rx, identity, data)
          messages_since_yield += 1
          bytes_since_yield += n
          if messages_since_yield >= RECV_FAIRNESS_MESSAGES || bytes_since_yield >= RECV_FAIRNESS_BYTES
            messages_since_yield = 0
            bytes_since_yield = 0
            Fiber.yield
          end
        end
      rescue IO::Error
      ensure
        notify_disconnect(rx, identity, disconnect_sent)
        close_signal.close unless close_signal.closed?
        rx.close unless rx.closed?
        tx.close unless tx.closed?
        tcp.close rescue nil
      end

      private def write_pump(
        tcp : TCPSocket,
        identity : Bytes,
        tx : Channel(Message),
        rx : Channel(Message),
        send_done : Channel(Nil),
        close_signal : Channel(Nil),
        disconnect_sent : Atomic(Bool),
      ) : Nil
        loop do
          msg = receive_send(tx, close_signal)
          break unless msg
          data = msg[0]? || Bytes.empty
          break if data.empty?
          tcp.write(data)
          tcp.flush
        end
      rescue Channel::ClosedError | IO::Error
      ensure
        notify_disconnect(rx, identity, disconnect_sent)
        close_signal.close unless close_signal.closed?
        send_done.close unless send_done.closed?
        tx.close unless tx.closed?
        rx.close unless rx.closed?
        tcp.close rescue nil
      end

      private def notify(rx : Channel(Message), identity : Bytes, data : Bytes) : Nil
        rx.send(Message{identity.dup, data})
      rescue Channel::ClosedError
      end

      private def notify_disconnect(rx : Channel(Message), identity : Bytes, sent : Atomic(Bool)) : Nil
        return unless sent.compare_and_set(false, true)[1]
        notify(rx, identity, Bytes.empty)
      end

      private def receive_send(tx : Channel(Message), close_signal : Channel(Nil)) : Message?
        select
        when msg = tx.receive?
          msg
        when close_signal.receive?
          nil
        end
      end
    end
  end
end
