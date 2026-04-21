module OMQ
  module Routing
    # SUB routing: one drain fiber per pipe, matching the message's first
    # frame (topic) against the subscription prefix list before forwarding
    # to the app.
    #
    # Empty prefix matches every message. See `Pub` for the note on why
    # filtering lives on the SUB side in v0.1.
    class Sub < Strategy
      getter rx : Channel(Message)

      def initialize(capacity : Int32)
        @rx = Channel(Message).new(capacity)
        @prefixes = [] of Bytes
        @prefixes_mutex = Mutex.new
        @closed = false
      end

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if @closed
        @rx = Channel(Message).new(recv_hwm)
      end

      def subscribe(prefix : Bytes) : Nil
        @prefixes_mutex.synchronize do
          @prefixes << prefix unless @prefixes.any? { |p| p == prefix }
        end
      end

      def unsubscribe(prefix : Bytes) : Nil
        @prefixes_mutex.synchronize do
          @prefixes.reject! { |p| p == prefix }
        end
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
          next unless matches?(msg)
          begin
            @rx.send(msg)
          rescue Channel::ClosedError
            break
          end
        end
      end

      private def matches?(msg : Message) : Bool
        @prefixes_mutex.synchronize do
          return false if @prefixes.empty?
          topic = msg.first? || Bytes.empty
          @prefixes.any? do |prefix|
            prefix.size == 0 || (prefix.size <= topic.size && topic[0, prefix.size] == prefix)
          end
        end
      end
    end
  end
end
