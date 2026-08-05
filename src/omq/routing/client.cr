require "./round_robin_send"

module OMQ
  module Routing
    # CLIENT routing: round-robin send + fair-queue receive, matching
    # `Dealer` but with a different ZMTP socket type. No envelope.
    class Client < Strategy
      getter rx : Channel(Message)

      def initialize(tx_capacity : Int32, rx_capacity : Int32)
        @send = RoundRobinSend.new(tx_capacity)
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
          begin
            @rx.send(msg)
          rescue Channel::ClosedError
            break
          end
        end
      end
    end
  end
end
