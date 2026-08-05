module OMQ
  module Routing
    # SERVER routing: identity-based. Uses the peer's advertised identity
    # when present, otherwise generates a 4-byte routing ID.
    class Server < Strategy
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
        id = pipe.peer_identity.dup
        id = Random::Secure.random_bytes(4) if id.empty?
        pipe.peer_identity = id
        replace_route(id, pipe)
        spawn recv_pump(pipe, id)
      end

      def close : Nil
        return unless close_once
        @tx.close
        @rx.close
      end

      private def replace_route(id : Bytes, pipe : Pipe) : Nil
        old = @mutex.synchronize do
          previous = @pipes_by_id[id]?
          @pipes_by_id[id] = pipe
          previous
        end
        if old && !old.same?(pipe)
          old.mark_disconnect(DisconnectReason::Handover)
          old.close
        end
      end

      private def forget_route(id : Bytes, pipe : Pipe) : Nil
        @mutex.synchronize do
          current = @pipes_by_id[id]?
          @pipes_by_id.delete(id) if current && current.same?(pipe)
        end
      end

      private def recv_pump(pipe : Pipe, id : Bytes) : Nil
        while msg = pipe.rx.receive?
          prepended = Message.new(msg.size + 1)
          prepended << id
          msg.each { |p| prepended << p }
          begin
            @rx.send(prepended)
          rescue Channel::ClosedError
            break
          end
        end
      ensure
        forget_route(id, pipe)
      end

      private def dispatcher : Nil
        while msg = @tx.receive?
          next if msg.empty?
          id = msg[0]
          pipe = @mutex.synchronize { @pipes_by_id[id]? }
          next if pipe.nil?
          body = msg.size > 1 ? msg[1..] : Message.new
          begin
            pipe.tx.send(body)
          rescue Channel::ClosedError
            forget_route(id, pipe)
          end
        end
      end
    end
  end
end
