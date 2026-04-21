module OMQ
  # PAIR socket: exactly one peer, bidirectional, preserves message
  # boundaries. Works over inproc and TCP.
  class PAIR < Socket
    @@default_action = :bind

    SOCKET_TYPE = "PAIR"

    @pipe : Pipe?
    @pipe_ready : Channel(Pipe)

    def initialize(endpoint : String? = nil)
      @pipe_ready = Channel(Pipe).new(1)
      super(endpoint)
    end

    def send(msg : String) : self
      send_frames([msg.to_slice])
    end

    def send(msg : Bytes) : self
      send_frames([msg])
    end

    def send(msg : Array(String)) : self
      send_frames(msg.map(&.to_slice))
    end

    def send(msg : Array(Bytes)) : self
      send_frames(msg)
    end

    def <<(msg) : self
      send(msg)
    end

    def receive : Message
      pipe = await_pipe(@options.read_timeout)
      channel_receive(pipe.rx)
    rescue Channel::ClosedError
      raise ClosedError.new("socket closed while receiving")
    end

    def receive? : Message?
      pipe = await_pipe?
      return nil unless pipe
      pipe.rx.receive?
    end

    protected def socket_type : String
      SOCKET_TYPE
    end

    protected def attach_pipe(pipe : Pipe) : Nil
      if @pipe
        # PAIR accepts only one peer; drop subsequent.
        pipe.close
        return
      end
      @pipe_ready.send(pipe)
    rescue Channel::ClosedError
      pipe.close
    end

    protected def on_close : Nil
      @pipe_ready.close
    end

    private def send_frames(frames : Message) : self
      pipe = await_pipe(@options.write_timeout)
      channel_send(pipe.tx, frames)
      self
    rescue Channel::ClosedError
      raise ClosedError.new("socket closed while sending")
    end

    private def await_pipe(timeout span : Time::Span? = nil) : Pipe
      if pipe = @pipe
        return pipe
      end
      pipe = if span
               select
               when p = @pipe_ready.receive
                 p
               when timeout(span)
                 raise IO::TimeoutError.new("no peer connected after #{span}")
               end
             else
               @pipe_ready.receive
             end
      @pipe = pipe
      pipe
    end

    private def await_pipe? : Pipe?
      if pipe = @pipe
        return pipe
      end
      pipe = @pipe_ready.receive?
      @pipe = pipe if pipe
      pipe
    end
  end
end
