module OMQ
  module QueueReadable
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
end
