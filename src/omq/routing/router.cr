module OMQ
  module Routing
    # ROUTER routing: identity-based.
    #
    # On receive, prepends the originating peer's identity as the first
    # frame. On send, the app's first frame is the routing identity —
    # the matching pipe is looked up and the remaining frames are sent
    # along that pipe. Unknown identities are silently dropped unless
    # `router_mandatory` is set; then `#send` raises.
    class Router < Strategy
      getter rx : Channel(Message)
      getter tx : Channel(Message)
      getter? router_mandatory : Bool

      def initialize(tx_capacity : Int32, rx_capacity : Int32, @router_mandatory = false)
        @tx = Channel(Message).new(tx_capacity)
        @rx = Channel(Message).new(rx_capacity)
        @pipes_by_id = {} of Bytes => Pipe
        @mutex = Mutex.new
        @closed = false
        spawn dispatcher
      end

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if @closed
        @tx.close
        @tx = Channel(Message).new(send_hwm)
        @rx = Channel(Message).new(recv_hwm)
        spawn dispatcher
      end

      def attach(pipe : Pipe) : Nil
        return if @closed
        identity = pipe.peer_identity
        identity = Random::Secure.random_bytes(5) if identity.empty?
        @mutex.synchronize { @pipes_by_id[identity] = pipe }
        spawn recv_pump(pipe, identity)
      end

      def close : Nil
        return if @closed
        @closed = true
        @tx.close
        @rx.close
      end

      # Returns nil if the identity is unknown; subclasses may override
      # behavior by choosing whether to raise or drop.
      def route?(identity : Bytes) : Pipe?
        @mutex.synchronize { @pipes_by_id[identity]? }
      end

      private def recv_pump(pipe : Pipe, identity : Bytes) : Nil
        while msg = pipe.rx.receive?
          prepended = Message.new(msg.size + 1)
          prepended << identity
          msg.each { |p| prepended << p }
          begin
            @rx.send(prepended)
          rescue Channel::ClosedError
            break
          end
        end
      ensure
        @mutex.synchronize { @pipes_by_id.delete(identity) }
      end

      private def dispatcher : Nil
        while msg = @tx.receive?
          if msg.empty?
            next
          end
          identity = msg[0]
          pipe = route?(identity)
          if pipe.nil?
            next
          end
          body = msg.size > 1 ? msg[1..] : Message.new
          begin
            pipe.tx.send(body)
          rescue Channel::ClosedError
            @mutex.synchronize { @pipes_by_id.delete(identity) }
          end
        end
      end
    end
  end
end
