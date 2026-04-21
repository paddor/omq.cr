module OMQ
  # Bounded queue with non-blocking push that honors a drop policy when
  # full. Used by PUB/XPUB/RADIO fan-out per-peer queues so a slow
  # subscriber can't back-pressure the publisher.
  #
  #   :drop_newest — reject the incoming item, keep the existing queue
  #   :drop_oldest — evict the head, then enqueue the new item
  #
  # Built on `Deque` + `Mutex` (instead of `Channel`) because `Channel`
  # does not expose "pop head to make room" needed for :drop_oldest
  # without racing the actual consumer. A capacity-1 `Channel(Nil)` is
  # used purely as a signal — receivers park on it when the queue is
  # empty and are woken by the next successful push or by `close`.
  class DropQueue(T)
    getter? closed : Bool = false

    def initialize(@capacity : Int32, @strategy : Options::MuteStrategy)
      @items = Deque(T).new
      @mutex = Mutex.new
      @signal = Channel(Nil).new(1)
    end

    # Non-blocking enqueue. Returns true if the item was accepted.
    # Returns false only for :drop_newest when the queue is full.
    def push(item : T) : Bool
      @mutex.synchronize do
        return false if @closed
        if @items.size >= @capacity
          case @strategy
          when Options::MuteStrategy::DropNewest
            return false
          when Options::MuteStrategy::DropOldest
            @items.shift
          else
            raise "DropQueue#push called with Block strategy"
          end
        end
        @items << item
      end
      wake
      true
    end

    # Block until an item is available. Returns nil if the queue was
    # closed and drained.
    def receive? : T?
      loop do
        val = @mutex.synchronize do
          item = @items.shift?
          {item, @closed}
        end
        item, was_closed = val
        return item if item
        return nil if was_closed
        @signal.receive?
        return nil if @closed && @mutex.synchronize { @items.empty? }
      end
    end

    def close : Nil
      @mutex.synchronize { @closed = true }
      @signal.close
    end

    private def wake : Nil
      select
      when @signal.send(nil)
      else
        # Signal already pending; receivers will pick up on next drain.
      end
    end
  end
end
