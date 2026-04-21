module OMQ
  module Routing
    # PUB routing: fan-out to every connected peer.
    #
    # v0.1 does not yet negotiate SUBSCRIBE/CANCEL over the wire; every
    # message is fanned out and filtering happens on the SUB side. This
    # is correct for OMQ-to-OMQ traffic on any transport, but wastes
    # bandwidth on TCP and does not interoperate with libzmq PUB sockets
    # (which require SUBSCRIBE before they send). Wire-level subscribe
    # support is tracked separately.
    class Pub < Strategy
      getter tx : Channel(Message)

      def initialize(capacity : Int32)
        @tx = Channel(Message).new(capacity)
        @pipes = [] of Pipe
        @pipes_mutex = Mutex.new
        @closed = false
        spawn dispatcher
      end

      def attach(pipe : Pipe) : Nil
        return if @closed
        @pipes_mutex.synchronize { @pipes << pipe }
      end

      def close : Nil
        return if @closed
        @closed = true
        @tx.close
      end

      private def dispatcher : Nil
        while msg = @tx.receive?
          snapshot = @pipes_mutex.synchronize { @pipes.dup }
          snapshot.each do |pipe|
            begin
              pipe.tx.send(msg)
            rescue Channel::ClosedError
              @pipes_mutex.synchronize { @pipes.delete(pipe) }
            end
          end
        end
      end
    end
  end
end
