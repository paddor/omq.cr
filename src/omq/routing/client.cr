module OMQ
  module Routing

    # CLIENT routing: work-stealing send + fair-queue receive, matching
    # `Dealer` but with a different ZMTP socket-type. No envelope.
    class Client < Strategy
      getter tx : Channel(Message)
      getter rx : Channel(Message)


      def initialize(tx_capacity : Int32, rx_capacity : Int32)
        @tx     = Channel(Message).new(tx_capacity)
        @rx     = Channel(Message).new(rx_capacity)
        @closed = false
      end


      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if @closed
        @tx = Channel(Message).new(send_hwm)
        @rx = Channel(Message).new(recv_hwm)
      end


      def attach(pipe : Pipe) : Nil
        return if @closed
        spawn send_pump(pipe)
        spawn recv_pump(pipe)
      end


      def close : Nil
        return if @closed
        @closed = true
        @tx.close
        @rx.close
      end


      private def send_pump(pipe : Pipe) : Nil
        while msg = @tx.receive?
          begin
            pipe.tx.send(msg)
          rescue Channel::ClosedError
            break
          end
        end
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
