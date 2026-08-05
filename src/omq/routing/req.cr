require "./round_robin_send"

module OMQ
  module Routing
    # REQ routing: prepends an empty delimiter frame on send and strips
    # the routing envelope (everything up to and including the first
    # empty frame) on receive. Sends round-robin across peers.
    #
    # Alternation (send, recv, send, recv, ...) is the caller's
    # responsibility — REQ sockets should be used from one fiber.
    class Req < Strategy
      EMPTY = Bytes.empty

      getter rx : Channel(Message)

      def initialize(tx_capacity : Int32, rx_capacity : Int32)
        @send = RoundRobinSend.new(tx_capacity, ->(msg : Message) { self.class.add_delimiter(msg) })
        @rx = Channel(Message).new(rx_capacity)
        @closed = Atomic(Bool).new(false)
      end

      delegate tx, to: @send

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if closed?
        @send.commit_capacity(send_hwm)
        @rx = Channel(Message).new(recv_hwm)
      end

      def attach(pipe : Pipe) : Nil
        return if closed?
        @send.attach(pipe)
        spawn recv_pump(pipe)
      end

      def close : Nil
        return unless close_once
        @send.close
        @rx.close
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

      def self.add_delimiter(msg : Message) : Message
        wire = Message.new(msg.size + 1)
        wire << EMPTY
        msg.each { |p| wire << p }
        wire
      end
    end
  end
end
