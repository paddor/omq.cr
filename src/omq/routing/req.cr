module OMQ
  module Routing
    # REQ routing: prepends an empty delimiter frame on send and strips
    # the routing envelope (everything up to and including the first
    # empty frame) on receive. Work-stealing across peers via a shared
    # tx channel; one recv pump per peer.
    #
    # Alternation (send, recv, send, recv, ...) is the caller's
    # responsibility — REQ sockets should be used from one fiber.
    class Req < Strategy
      EMPTY = Bytes.empty

      getter tx : Channel(Message)
      getter rx : Channel(Message)

      def initialize(tx_capacity : Int32, rx_capacity : Int32)
        @tx = Channel(Message).new(tx_capacity)
        @rx = Channel(Message).new(rx_capacity)
        @closed = false
      end

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if @closed
        @tx = Channel(Message).new(send_hwm)
        @rx = Channel(Message).new(recv_hwm)
      end

      def attach(pipe : Pipe) : Nil
        return if @closed
        spawn send_pump(pipe)
        spawn recv_pump(pipe)
      end

      def close : Nil
        return if @closed
        @closed = true
        @tx.close
        @rx.close
      end

      private def send_pump(pipe : Pipe) : Nil
        while msg = @tx.receive?
          wire = Message.new(msg.size + 1)
          wire << EMPTY
          msg.each { |p| wire << p }
          begin
            pipe.tx.send(wire)
          rescue Channel::ClosedError
            break
          end
        end
      end

      private def recv_pump(pipe : Pipe) : Nil
        while msg = pipe.rx.receive?
          start_i = 0
          msg.each_with_index do |p, i|
            if p.empty?
              start_i = i + 1
              break
            end
          end
          body = start_i == 0 ? msg : msg[start_i..]
          begin
            @rx.send(body)
          rescue Channel::ClosedError
            break
          end
        end
      end
    end
  end
end
