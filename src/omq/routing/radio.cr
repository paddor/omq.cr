module OMQ
  module Routing

    # RADIO routing: broadcast `[group, body]` to every attached DISH
    # peer. v0.1 does not yet track JOIN/LEAVE per-peer — messages go
    # to all peers and DISH filters locally. Matches the simplified
    # PUB/SUB story for the non-draft counterpart.
    class Radio < Strategy
      getter tx : ::Channel(Message)


      def initialize(capacity : Int32)
        @tx          = ::Channel(Message).new(capacity)
        @pipes       = [] of Pipe
        @pipes_mutex = Mutex.new
        @closed      = false
      end


      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if @closed
        @tx = ::Channel(Message).new(send_hwm)
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
            rescue ::Channel::ClosedError
              @pipes_mutex.synchronize { @pipes.delete(pipe) }
            end
          end
        end
      end
    end
  end
end
