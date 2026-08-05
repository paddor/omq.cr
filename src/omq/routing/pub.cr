module OMQ
  module Routing
    # PUB routing: fan-out to subscribed peers. SUBSCRIBE/CANCEL commands
    # are tracked per pipe so unjoined peers never receive unmatched data.
    class Pub < Strategy
      getter tx : Channel(Message)
      getter subscriber_joined : Channel(Pipe)

      # When on_mute is a drop strategy, each peer gets its own DropQueue
      # and a forwarder fiber draining into pipe.tx. In Block mode we
      # fan out to pipe.tx directly — the dispatcher blocks on any slow
      # peer, same as libzmq ZMQ_XPUB_NODROP.
      record PeerSlot, pipe : Pipe, drop : DropQueue(Message)?

      def initialize(capacity : Int32, @conflate : Bool = false, @on_mute : Options::MuteStrategy = Options::MuteStrategy::Block)
        @tx = Channel(Message).new(capacity)
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

      # Called once on first bind/connect (via Socket's commit gate).
      # Installs the finalized @tx capacity and starts the dispatcher.
      def commit_capacity(send_hwm : Int32, recv_hwm : Int32, conflate : Bool, on_mute : Options::MuteStrategy) : Nil
        return if closed?

        @conflate = conflate
        @on_mute = on_mute
        @peer_hwm = send_hwm
        @tx = Channel(Message).new(send_hwm)

        spawn dispatcher
      end

      def attach(pipe : Pipe) : Nil
        return if closed?
        slot = build_slot(pipe)
        @pipes_mutex.synchronize do
          @peer_slots << slot
          @subscriptions_mutex.synchronize { @subscriptions[pipe] = [] of Bytes }
        end
        spawn command_listener(pipe)
      end

      def close : Nil
        return unless close_once
        @tx.close
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

      # Drains a per-peer DropQueue into the pipe's tx. A blocking send
      # to pipe.tx is fine here — the DropQueue upstream has already
      # absorbed any burst, and pipe.tx's own HWM acts as a second,
      # peer-level backstop.
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

      private def command_listener(pipe : Pipe) : Nil
        commands = pipe.commands_rx
        return unless commands
        while event = commands.receive?
          case event.name
          when "SUBSCRIBE"
            subscribe(pipe, event.body)
          when "CANCEL"
            unsubscribe(pipe, event.body)
          end
        end
      ensure
        remove_pipe(pipe)
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
            # Conflate: drain any further queued messages non-blockingly
            # and keep only the most recent one. Stale updates get dropped
            # so slow subscribers see only the latest state, not backlog.
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
