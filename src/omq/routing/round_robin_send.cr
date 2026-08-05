require "sync/condition_variable"
require "wait_group"

module OMQ
  module Routing
    # Shared round-robin send core for PUSH-style sockets. Application
    # sends enter `tx`; a dispatcher moves them to bounded per-peer slots
    # in round-robin order. Full slots are skipped, so a slow peer cannot
    # block fast peers until every peer is full.
    class RoundRobinSend
      getter tx : Channel(Message)

      class Slot
        getter pipe : Pipe

        @queue : Deque(Message)

        def initialize(@pipe : Pipe, @capacity : Int32, @owner : RoundRobinSend)
          @queue = Deque(Message).new
          @mutex = Mutex.new
          @not_empty = Sync::ConditionVariable.new(@mutex)
          @closing = false
          @closed = false
        end

        def try_push(msg : Message) : Bool
          @mutex.synchronize do
            return false if @pipe.closed? || @closing || @closed || @queue.size >= @capacity
            @queue << msg
            @not_empty.signal
            true
          end
        end

        def pop : Message?
          msg = @mutex.synchronize do
            while @queue.empty? && !@closing && !@closed
              @not_empty.wait
            end

            if @queue.empty?
              @closed = true
              nil
            else
              @queue.shift
            end
          end

          @owner.notify_space if msg
          msg
        end

        def close_send : Nil
          @mutex.synchronize do
            @closing = true
            @not_empty.broadcast
          end
        end

        def close : Nil
          @mutex.synchronize do
            @closing = true
            @closed = true
            @queue.clear
            @not_empty.broadcast
          end
        end
      end

      @slots : Array(Slot)
      @waiters : Array(Channel(Nil))
      @transform : Proc(Message, Message)?

      def initialize(capacity : Int32, @transform : Proc(Message, Message)? = nil)
        @tx = Channel(Message).new(capacity)
        @slot_capacity = capacity
        @slots = [] of Slot
        @cursor = 0
        @mutex = Mutex.new
        @waiters = [] of Channel(Nil)
        @closed = false
        @dispatcher_started = false
        @pumps = WaitGroup.new
      end

      def commit_capacity(capacity : Int32) : Nil
        @tx = Channel(Message).new(capacity)
        @slot_capacity = capacity
      end

      def attach(pipe : Pipe) : Nil
        slot = Slot.new(pipe, @slot_capacity, self)
        should_start = @mutex.synchronize do
          if @closed
            false
          else
            @slots << slot
            wake_all_locked
            true
          end
        end

        if should_start
          start_dispatcher
          @pumps.spawn { pump(slot) }
          spawn watch_pipe_close(slot)
        else
          slot.close
          pipe.close
        end
      end

      def close_send : Nil
        @tx.close unless @tx.closed?
      end

      def close : Nil
        slots = @mutex.synchronize do
          return if @closed
          @closed = true
          wake_all_locked
          @slots.dup
        end

        @tx.close unless @tx.closed?
        slots.each(&.close)
      end

      def await_drained(span : Time::Span?) : Bool
        done = Channel(Nil).new
        spawn do
          @pumps.wait
          done.close
        end

        case span
        when nil
          done.receive?
          true
        else
          select
          when done.receive?
            true
          when timeout(span)
            false
          end
        end
      end

      protected def notify_space : Nil
        @mutex.synchronize { wake_all_locked }
      end

      private def start_dispatcher : Nil
        should_start = @mutex.synchronize do
          unless @dispatcher_started
            @dispatcher_started = true
            true
          else
            false
          end
        end
        @pumps.spawn { dispatcher } if should_start
      end

      private def dispatcher : Nil
        while msg = @tx.receive?
          msg = @transform.try(&.call(msg)) || msg
          route(msg)
        end
      ensure
        slots = @mutex.synchronize { @slots.dup }
        slots.each(&.close_send)
      end

      private def route(msg : Message) : Nil
        loop do
          waiter = @mutex.synchronize do
            return if @closed
            if try_route_locked(msg)
              nil
            else
              new_waiter = Channel(Nil).new
              @waiters << new_waiter
              new_waiter
            end
          end

          return unless waiter
          waiter.receive?
        end
      end

      private def try_route_locked(msg : Message) : Bool
        compact_closed_slots_locked
        count = @slots.size
        return false if count == 0

        count.times do |offset|
          index = (@cursor + offset) % count
          slot = @slots[index]
          next unless slot.try_push(msg)

          @cursor = (index + 1) % count
          return true
        end

        false
      end

      private def pump(slot : Slot) : Nil
        while msg = slot.pop
          break unless send_to_pipe(slot.pipe, msg)
        end
      ensure
        slot.close
        remove_slot(slot)
      end

      private def send_to_pipe(pipe : Pipe, msg : Message) : Bool
        select
        when pipe.tx.send(msg)
          true
        when pipe.close_signal.receive?
          false
        end
      rescue Channel::ClosedError
        false
      end

      private def watch_pipe_close(slot : Slot) : Nil
        slot.pipe.close_signal.receive?
      ensure
        slot.close
        notify_space
      end

      private def remove_slot(slot : Slot) : Nil
        @mutex.synchronize do
          if index = @slots.index { |candidate| candidate.same?(slot) }
            @slots.delete_at(index)
            if @slots.empty?
              @cursor = 0
            elsif index < @cursor
              @cursor -= 1
            elsif @cursor >= @slots.size
              @cursor = 0
            end
            wake_all_locked
          end
        end
      end

      private def compact_closed_slots_locked : Nil
        closed_slots = @slots.select { |slot| slot.pipe.closed? }
        return if closed_slots.empty?

        closed_slots.each(&.close)
        @slots.reject! { |slot| slot.pipe.closed? }
        @cursor = @slots.empty? ? 0 : @cursor % @slots.size
        wake_all_locked
      end

      private def wake_all_locked : Nil
        @waiters.each do |waiter|
          waiter.close unless waiter.closed?
        end
        @waiters.clear
      end
    end
  end
end
