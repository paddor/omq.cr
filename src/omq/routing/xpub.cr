module OMQ
  module Routing
    # XPUB routing: same fan-out + on_mute semantics as `Pub`, plus a
    # peer-rx fan-in. Subscribe/cancel events sent by XSUB peers arrive
    # as ZMTP 3.0 legacy data frames whose first byte is 0x01 (subscribe)
    # or 0x00 (cancel). XPUB surfaces them verbatim on rx — no wire-level
    # interpretation, the app decides.
    class XPub < Strategy
      getter tx : Channel(Message)
      getter rx : Channel(Message)
      getter subscriber_joined : Channel(Pipe)

      record PeerSlot, pipe : Pipe, drop : DropQueue(Message)?

      def initialize(capacity : Int32, @conflate : Bool = false, @on_mute : Options::MuteStrategy = Options::MuteStrategy::Block)
        @tx = Channel(Message).new(capacity)
        @rx = Channel(Message).new(capacity)
        @subscriber_joined = Channel(Pipe).new(128)
        @subscription_count = Atomic(Int64).new(0)
        @subscription_signal = Channel(Nil).new(1)
        @peer_slots = [] of PeerSlot
        @pipes_mutex = Mutex.new
        @subscriptions = {} of Pipe => Array(Bytes)
        @subscriptions_mutex = Mutex.new
        @closed = Atomic(Bool).new(false)
        @peer_hwm = capacity
      end

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32, conflate : Bool, on_mute : Options::MuteStrategy) : Nil
        return if closed?

        @conflate = conflate
        @on_mute = on_mute
        @peer_hwm = send_hwm
        @tx = Channel(Message).new(send_hwm)
        @rx = Channel(Message).new(recv_hwm)

        spawn dispatcher
      end

      def attach(pipe : Pipe) : Nil
        return if closed?
        slot = build_slot(pipe)
        @pipes_mutex.synchronize do
          @peer_slots << slot
          @subscriptions_mutex.synchronize { @subscriptions[pipe] = [] of Bytes }
        end
        spawn recv_pump(pipe)
        spawn command_listener(pipe)
      end

      def close : Nil
        return unless close_once
        @tx.close
        @rx.close
        @subscriber_joined.close
        @subscription_signal.close
        @pipes_mutex.synchronize do
          @peer_slots.each { |s| s.drop.try(&.close) }
        end
      end

      def subscription_count : Int64
        @subscription_count.get
      end

      def wait_subscribed(min_subscriptions : Int, timeout : Time::Span) : Int64
        wait_for_subscription_count(min_subscriptions, timeout)
      end

      private def build_slot(pipe : Pipe) : PeerSlot
        case @on_mute
        when Options::MuteStrategy::Block
          PeerSlot.new(pipe: pipe, drop: nil)
        else
          drop = DropQueue(Message).new(@peer_hwm, @on_mute)
          spawn forward(drop, pipe)
          PeerSlot.new(pipe: pipe, drop: drop)
        end
      end

      private def forward(drop : DropQueue(Message), pipe : Pipe) : Nil
        while msg = drop.receive?
          begin
            pipe.tx.send(msg)
          rescue Channel::ClosedError
            break
          end
        end
      ensure
        drop.close
        remove_pipe(pipe)
      end

      private def recv_pump(pipe : Pipe) : Nil
        while msg = pipe.rx.receive?
          track_legacy_subscription(pipe, msg)
          begin
            @rx.send(msg)
          rescue Channel::ClosedError
            break
          end
        end
      ensure
        remove_pipe(pipe)
      end

      private def command_listener(pipe : Pipe) : Nil
        commands = pipe.commands_rx
        return unless commands
        while event = commands.receive?
          case event.name
          when "SUBSCRIBE"
            subscribe(pipe, event.body)
            send_subscription_marker(0x01_u8, event.body)
          when "CANCEL"
            unsubscribe(pipe, event.body)
            send_subscription_marker(0x00_u8, event.body)
          end
        end
      ensure
        remove_pipe(pipe)
      end

      private def track_legacy_subscription(pipe : Pipe, msg : Message) : Nil
        frame = msg.first? || return
        return if frame.empty?
        prefix = frame[1..]
        case frame[0]
        when 0x01_u8
          subscribe(pipe, prefix)
        when 0x00_u8
          unsubscribe(pipe, prefix)
        end
      end

      private def subscribe(pipe : Pipe, prefix : Bytes) : Nil
        @subscriptions_mutex.synchronize do
          prefixes = @subscriptions[pipe]? || return
          return if prefixes.any? { |p| p == prefix }
          prefixes << prefix.dup
        end
        @subscription_count.add(1)
        signal_subscription
        notify_subscriber_joined(pipe)
      end

      private def unsubscribe(pipe : Pipe, prefix : Bytes) : Nil
        @subscriptions_mutex.synchronize do
          prefixes = @subscriptions[pipe]? || return
          prefixes.reject! { |p| p == prefix }
        end
      end

      private def subscribed?(pipe : Pipe, topic : Bytes) : Bool
        @subscriptions_mutex.synchronize do
          prefixes = @subscriptions[pipe]?
          return false unless prefixes
          prefixes.any? do |prefix|
            prefix.empty? || (prefix.size <= topic.size && topic[0, prefix.size] == prefix)
          end
        end
      end

      private def remove_pipe(pipe : Pipe) : Nil
        @pipes_mutex.synchronize do
          @peer_slots.reject! { |slot| slot.pipe == pipe }
        end
        @subscriptions_mutex.synchronize { @subscriptions.delete(pipe) }
      end

      private def notify_subscriber_joined(pipe : Pipe) : Nil
        select
        when @subscriber_joined.send(pipe)
        else
        end
      rescue Channel::ClosedError
      end

      private def send_subscription_marker(marker : UInt8, prefix : Bytes) : Nil
        frame = Bytes.new(prefix.size + 1)
        frame[0] = marker
        prefix.copy_to(frame + 1) if prefix.size > 0
        @rx.send(Message{frame})
      rescue Channel::ClosedError
      end

      private def signal_subscription : Nil
        select
        when @subscription_signal.send(nil)
        else
        end
      rescue Channel::ClosedError
      end

      private def wait_for_subscription_count(min_subscriptions : Int, timeout : Time::Span) : Int64
        raise ArgumentError.new("min_subscriptions must be >= 0") if min_subscriptions < 0
        deadline = Time.instant + timeout
        loop do
          count = subscription_count
          return count if count >= min_subscriptions
          raise ClosedError.new("socket closed while waiting for subscriptions") if closed?

          remaining = deadline - Time.instant
          raise IO::TimeoutError.new("wait_subscribed timed out after #{timeout}") unless remaining.positive?
          select
          when @subscription_signal.receive?
          when timeout(remaining)
            raise IO::TimeoutError.new("wait_subscribed timed out after #{timeout}")
          end
        end
      end

      private def dispatcher : Nil
        while msg = @tx.receive?
          topic = msg.first? || Bytes.empty
          if @conflate
            loop do
              select
              when newer = @tx.receive
                msg = newer
                topic = msg.first? || Bytes.empty
              else
                break
              end
            end
          end

          snapshot = @pipes_mutex.synchronize { @peer_slots.dup }
          snapshot.each do |slot|
            next unless subscribed?(slot.pipe, topic)
            if drop = slot.drop
              drop.push(msg)
            else
              begin
                slot.pipe.tx.send(msg)
              rescue Channel::ClosedError
                remove_pipe(slot.pipe)
              end
            end
          end
        end
      end
    end
  end
end
