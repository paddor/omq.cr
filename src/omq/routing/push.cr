require "./round_robin_send"

module OMQ
  module Routing
    # Round-robin send: app writes to a single shared `tx` channel,
    # and a dispatcher assigns each message to the next peer with space.
    # Full peers are skipped until every peer is full.
    class Push < Strategy
      def initialize(capacity : Int32)
        @send = RoundRobinSend.new(capacity)
        @closed = Atomic(Bool).new(false)
      end

      delegate tx, to: @send

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if closed?
        @send.commit_capacity(send_hwm)
      end

      def attach(pipe : Pipe) : Nil
        return if closed?
        @send.attach(pipe)
      end

      def close_send : Nil
        return unless close_once
        @send.close_send
      end

      def close : Nil
        close_send
        @send.close
      end

      def await_drained(span : Time::Span?) : Bool
        @send.await_drained(span)
      end
    end
  end
end
