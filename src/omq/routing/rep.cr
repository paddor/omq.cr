module OMQ
  module Routing
    # REP routing: on receive, splits the wire message into an envelope
    # (everything up to the first empty frame) and a body (everything
    # after). Tracks the originating pipe + envelope as `@current` so
    # the matching reply can be routed back. Strict alternation
    # (recv, send, recv, send, ...) — REP sockets should be used from
    # one fiber.
    class Rep < Strategy
      EMPTY = Bytes.empty

      @rx : Channel({Pipe, Message, Message})
      @tx : Channel(Message)
      @current : {Pipe, Message}?

      def initialize(rx_capacity : Int32, tx_capacity : Int32)
        @rx = Channel({Pipe, Message, Message}).new(rx_capacity)
        @tx = Channel(Message).new(tx_capacity)
        @current = nil
        @closed = false
        spawn dispatcher
      end

      def attach(pipe : Pipe) : Nil
        return if @closed
        spawn recv_pump(pipe)
      end

      def close : Nil
        return if @closed
        @closed = true
        @rx.close
        @tx.close
      end

      def receive : Message
        pipe, envelope, body = @rx.receive
        @current = {pipe, envelope}
        body
      end

      def receive? : Message?
        triple = @rx.receive?
        return nil unless triple
        pipe, envelope, body = triple
        @current = {pipe, envelope}
        body
      end

      def send(msg : Message) : Nil
        @tx.send(msg)
      end

      private def recv_pump(pipe : Pipe) : Nil
        while msg = pipe.rx.receive?
          envelope, body = Rep.split(msg)
          begin
            @rx.send({pipe, envelope, body})
          rescue Channel::ClosedError
            break
          end
        end
      end

      private def dispatcher : Nil
        while reply = @tx.receive?
          cur = @current
          @current = nil
          next unless cur
          pipe, envelope = cur
          wire = Message.new(envelope.size + 1 + reply.size)
          envelope.each { |p| wire << p }
          wire << EMPTY
          reply.each { |p| wire << p }
          begin
            pipe.tx.send(wire)
          rescue Channel::ClosedError
            # peer gone mid-reply
          end
        end
      end

      def self.split(msg : Message) : {Message, Message}
        delim_i = nil
        msg.each_with_index do |p, i|
          if p.empty?
            delim_i = i
            break
          end
        end
        if d = delim_i
          {msg[0...d], msg[(d + 1)..]}
        else
          {Message.new, msg}
        end
      end
    end
  end
end
