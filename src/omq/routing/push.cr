require "wait_group"

module OMQ
  module Routing
    # Work-stealing send: app writes to a single shared `tx` channel,
    # and each attached pipe runs a pump fiber racing to drain it.
    # Fast peers dequeue more, slow peers block on their own wire —
    # strictly better fairness than libzmq's strict round-robin for
    # PUSH-style patterns.
    class Push < Strategy
      getter tx : Channel(Message)

      def initialize(capacity : Int32)
        @tx = Channel(Message).new(capacity)
        @closed = false
        @pumps = WaitGroup.new
      end

      def attach(pipe : Pipe) : Nil
        return if @closed
        @pumps.spawn { pump(pipe) }
      end

      def close_send : Nil
        return if @closed
        @closed = true
        @tx.close
      end

      def close : Nil
        close_send
      end

      def await_drained(span : Time::Span?) : Bool
        done = Channel(Nil).new
        spawn do
          @pumps.wait
          done.close
        end
        case span
        when nil
          done.receive?
          true
        else
          select
          when done.receive?
            true
          when timeout(span)
            false
          end
        end
      end

      private def pump(pipe : Pipe) : Nil
        while msg = @tx.receive?
          begin
            pipe.tx.send(msg)
          rescue Channel::ClosedError
            # peer gone; in-flight message drops (matches libzmq)
            break
          end
        end
      end
    end
  end
end
