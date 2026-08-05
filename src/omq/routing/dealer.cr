require "./round_robin_send"

module OMQ
  module Routing
    # DEALER routing: round-robin send + fair-queue receive. No envelope
    # manipulation.
    class Dealer < Strategy
      getter rx : Channel(Message)

      def initialize(tx_capacity : Int32, rx_capacity : Int32)
        @send = RoundRobinSend.new(tx_capacity)
        @rx = Channel(Message).new(rx_capacity)
        @conflate_recv = false
        @closed = Atomic(Bool).new(false)
      end

      delegate tx, to: @send

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32, conflate_recv : Bool = false) : Nil
        return if closed?
        @send.commit_capacity(send_hwm)
        @conflate_recv = conflate_recv
        @rx = Channel(Message).new(conflate_recv ? 1 : recv_hwm)
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
          break unless deliver_receive(@rx, msg, @conflate_recv)
        end
      end
    end
  end
end
