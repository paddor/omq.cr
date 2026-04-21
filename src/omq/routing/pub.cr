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

      def initialize(capacity : Int32, @conflate : Bool = false)
        @tx = Channel(Message).new(capacity)
        @pipes = [] of Pipe
        @pipes_mutex = Mutex.new
        @closed = false
      end

      # Called once on first bind/connect (via Socket's commit gate).
      # Installs the finalized @tx capacity and starts the dispatcher.
      def commit_capacity(send_hwm : Int32, recv_hwm : Int32, conflate : Bool) : Nil
        return if @closed
        @conflate = conflate
        @tx = Channel(Message).new(send_hwm)
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
          if @conflate
            # Conflate: drain any further queued messages non-blockingly
            # and keep only the most recent one. Stale updates get dropped
            # so slow subscribers see only the latest state, not backlog.
            loop do
              select
              when newer = @tx.receive
                msg = newer
              else
                break
              end
            end
          end
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
