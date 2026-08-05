module OMQ
  module Routing
    # GATHER routing: fair-queue receive from SCATTER peers. Same
    # mechanics as `Pull` — one drain fiber per pipe, single shared
    # `rx` channel.
    class Gather < Strategy
      getter rx : Channel(Message)

      def initialize(capacity : Int32)
        @rx = Channel(Message).new(capacity)
        @conflate = false
        @closed = Atomic(Bool).new(false)
      end

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32, conflate : Bool = false) : Nil
        return if closed?
        @conflate = conflate
        @rx = Channel(Message).new(conflate ? 1 : recv_hwm)
      end

      def attach(pipe : Pipe) : Nil
        return if closed?
        spawn drain(pipe)
      end

      def close : Nil
        return unless close_once
        @rx.close
      end

      private def drain(pipe : Pipe) : Nil
        while msg = pipe.rx.receive?
          break unless deliver_receive(@rx, msg, @conflate)
        end
      end
    end
  end
end
