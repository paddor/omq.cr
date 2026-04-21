module OMQ
  module Routing

    # XSUB routing: broadcasts outbound messages to every connected peer
    # (so subscribe/cancel commands reach every upstream XPUB), and
    # fans in inbound messages with no local filter — the app sees every
    # frame that lands. Subscribe/cancel on the wire are ZMTP 3.0 legacy
    # data frames whose first byte is 0x01 / 0x00; `XSUB#subscribe` /
    # `#unsubscribe` are convenience wrappers that prepend those bytes.
    class XSub < Strategy
      getter tx : Channel(Message)
      getter rx : Channel(Message)


      def initialize(capacity : Int32)
        @tx          = Channel(Message).new(capacity)
        @rx          = Channel(Message).new(capacity)
        @pipes       = [] of Pipe
        @pipes_mutex = Mutex.new
        @closed      = false
      end

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if @closed

        @tx = Channel(Message).new(send_hwm)
        @rx = Channel(Message).new(recv_hwm)

        spawn dispatcher
      end

      def attach(pipe : Pipe) : Nil
        return if @closed
        @pipes_mutex.synchronize { @pipes << pipe }
        spawn recv_pump(pipe)
      end

      def close : Nil
        return if @closed
        @closed = true
        @tx.close
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
