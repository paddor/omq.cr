require "wait_group"

module OMQ
  module Routing

    # SCATTER routing: work-stealing send across GATHER peers. Same
    # mechanics as `Push` — shared `tx` channel, per-pipe pump fiber.
    class Scatter < Strategy
      getter tx : Channel(Message)


      def initialize(capacity : Int32)
        @tx     = Channel(Message).new(capacity)
        @closed = false
        @pumps  = WaitGroup.new
      end


      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if @closed
        @tx = Channel(Message).new(send_hwm)
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
            break
          end
        end
      end
    end
  end
end
