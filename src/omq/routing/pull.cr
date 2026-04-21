module OMQ
  module Routing
    # Fair-queue receive: every attached pipe runs a drain fiber that
    # pushes incoming messages into a single `rx` channel. The channel's
    # capacity bounds how much a fast peer can queue before blocking,
    # which is how backpressure fans out to the wire.
    class Pull < Strategy
      getter rx : Channel(Message)

      def initialize(capacity : Int32)
        @rx = Channel(Message).new(capacity)
        @closed = false
      end

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if @closed
        @rx = Channel(Message).new(recv_hwm)
      end

      def attach(pipe : Pipe) : Nil
        return if @closed
        spawn drain(pipe)
      end

      def close : Nil
        return if @closed
        @closed = true
        @rx.close
      end

      private def drain(pipe : Pipe) : Nil
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
