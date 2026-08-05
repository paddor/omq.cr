module OMQ
  module Routing
    # STREAM routing: identity-based raw TCP.
    #
    # The raw transport already delivers identity-prefixed messages. Send
    # messages use `[identity, data]`; an empty data frame closes that peer.
    class Stream < Strategy
      getter rx : Channel(Message)
      getter tx : Channel(Message)

      def initialize(tx_capacity : Int32, rx_capacity : Int32)
        @tx = Channel(Message).new(tx_capacity)
        @rx = Channel(Message).new(rx_capacity)
        @pipes_by_id = {} of Bytes => Pipe
        @mutex = Mutex.new
        @closed = Atomic(Bool).new(false)
      end

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if closed?
        @tx = Channel(Message).new(send_hwm)
        @rx = Channel(Message).new(recv_hwm)
        spawn dispatcher
      end

      def attach(pipe : Pipe) : Nil
        return if closed?
        identity = pipe.peer_identity
        identity = Random::Secure.random_bytes(5) if identity.empty?
        pipe.peer_identity = identity
        @mutex.synchronize { @pipes_by_id[identity] = pipe }
        spawn recv_pump(pipe, identity)
      end

      def close : Nil
        return unless close_once
        @tx.close
        @rx.close
      end

      def close_send : Nil
        @tx.close unless @tx.closed?
      end

      def route?(identity : Bytes) : Pipe?
        @mutex.synchronize { @pipes_by_id[identity]? }
      end

      private def recv_pump(pipe : Pipe, identity : Bytes) : Nil
        while msg = pipe.rx.receive?
          begin
            @rx.send(msg)
          rescue Channel::ClosedError
            break
          end
        end
      ensure
        @mutex.synchronize do
          current = @pipes_by_id[identity]?
          @pipes_by_id.delete(identity) if current == pipe
        end
      end

      private def dispatcher : Nil
        while msg = @tx.receive?
          next if msg.empty?
          identity = msg[0]
          pipe = route?(identity)
          next unless pipe
          data = msg[1]? || Bytes.empty
          begin
            select
            when pipe.tx.send(Message{data})
            when pipe.close_signal.receive?
              @mutex.synchronize do
                current = @pipes_by_id[identity]?
                @pipes_by_id.delete(identity) if current == pipe
              end
            end
          rescue Channel::ClosedError
            @mutex.synchronize do
              current = @pipes_by_id[identity]?
              @pipes_by_id.delete(identity) if current == pipe
            end
          end
        end
      end
    end
  end
end
