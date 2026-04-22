module OMQ
  module Routing

    # SUB routing: one drain fiber per pipe, matching the message's first
    # frame (topic) against the subscription prefix list before forwarding
    # to the app.
    #
    # `#subscribe` is two things at once: (1) it installs a local filter
    # so non-matching frames are dropped on arrival, and (2) it pushes a
    # subscribe notification upstream so libzmq/ruby-omq PUBs — which
    # filter upstream — actually send us matching traffic. The wire
    # encoding depends on the peer's ZMTP minor version: 3.1 uses a
    # SUBSCRIBE/CANCEL command frame; 3.0 uses a regular data frame
    # whose first byte is 0x01 (subscribe) or 0x00 (cancel). New pipes
    # get every current subscription replayed at attach time.
    class Sub < Strategy
      getter rx : Channel(Message)


      def initialize(capacity : Int32)
        @rx             = Channel(Message).new(capacity)
        @prefixes       = [] of Bytes
        @prefixes_mutex = Mutex.new
        @pipes          = [] of Pipe
        @pipes_mutex    = Mutex.new
        @closed         = false
      end

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if @closed
        @rx = Channel(Message).new(recv_hwm)
      end

      def subscribe(prefix : Bytes) : Nil
        @prefixes_mutex.synchronize do
          return if @prefixes.any? { |p| p == prefix }
          @prefixes << prefix
        end
        broadcast_marker(0x01_u8, prefix)
      end

      def unsubscribe(prefix : Bytes) : Nil
        @prefixes_mutex.synchronize do
          return unless @prefixes.any? { |p| p == prefix }
          @prefixes.reject! { |p| p == prefix }
        end
        broadcast_marker(0x00_u8, prefix)
      end

      def attach(pipe : Pipe) : Nil
        return if @closed
        @pipes_mutex.synchronize { @pipes << pipe }

        # Replay current subscriptions so the new peer knows which
        # topics to forward.
        snapshot = @prefixes_mutex.synchronize { @prefixes.dup }
        snapshot.each do |prefix|
          send_to(pipe, 0x01_u8, prefix)
        end

        spawn drain(pipe)
      end

      def close : Nil
        return if @closed
        @closed = true
        @rx.close
      end

      private def broadcast_marker(marker : UInt8, prefix : Bytes) : Nil
        snapshot = @pipes_mutex.synchronize { @pipes.dup }
        snapshot.each { |pipe| send_to(pipe, marker, prefix) }
      end

      private def send_to(pipe : Pipe, marker : UInt8, prefix : Bytes) : Nil
        if pipe.peer_zmtp_minor == 0
          # ZMTP 3.0: legacy data frame with \x01 / \x00 prefix byte.
          payload = Bytes.new(1 + prefix.size)
          payload[0] = marker
          prefix.copy_to(payload + 1) if prefix.size > 0
          begin
            pipe.tx.send(Message{payload})
          rescue Channel::ClosedError
            # peer gone — drop silently
          end
        else
          cmd = marker == 0x01_u8 ? ZMTP::Command.subscribe(prefix) : ZMTP::Command.cancel(prefix)
          pipe.send_command(cmd)
        end
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
