module OMQ
  module QueueReadable
    def try_dequeue : Message?
      try_receive
    end

    def try_pop : Message?
      try_receive
    end

    def dequeue(*, timeout : Time::Span? = @options.read_timeout) : Message
      old_timeout = @options.read_timeout
      @options.read_timeout = timeout
      receive
    ensure
      @options.read_timeout = old_timeout
    end

    def pop(*, timeout : Time::Span? = @options.read_timeout) : Message
      dequeue(timeout: timeout)
    end

    def wait : Message
      dequeue(timeout: nil)
    end

    def each(&block : Message ->) : Nil
      loop do
        yield receive
      end
    rescue IO::TimeoutError | ClosedError
    end
  end

  module QueueWritable
    def enqueue(*messages) : self
      messages.each { |msg| send(msg) }
      self
    end

    def push(*messages) : self
      enqueue(*messages)
    end
  end

  module TryReadable
    def try_receive : Message?
      channel_try_receive(@strategy.rx)
    end

    def try_recv : Message?
      try_receive
    end
  end

  module MultipartTryWritable
    def try_send(msg : String) : Bool
      try_send_frames([msg.to_slice])
    end

    def try_send(msg : Bytes) : Bool
      try_send_frames([msg])
    end

    def try_send(msg : Array(String)) : Bool
      try_send_frames(msg.map(&.to_slice))
    end

    def try_send(msg : Array(Bytes)) : Bool
      try_send_frames(msg)
    end

    private def try_send_frames(frames : Message) : Bool
      channel_try_send(@strategy.tx, frames)
    end
  end

  module SingleFrameTryWritable
    def try_send(msg : String) : Bool
      try_send_frames([msg.to_slice])
    end

    def try_send(msg : Bytes) : Bool
      try_send_frames([msg])
    end

    private def try_send_frames(frames : Message) : Bool
      channel_try_send(@strategy.tx, frames)
    end
  end
end
