module OMQ
  # PAIR socket: exactly one peer, bidirectional, preserves message boundaries.
  # Inproc-only in milestone 1; TCP/IPC to follow.
  class PAIR < Socket
    @@default_action = :bind

    @pipe : Transport::Inproc::Pipe?
    @pipe_ready : Channel(Transport::Inproc::Pipe)
    @listener : Transport::Inproc::Listener?
    @endpoint : String?

    def initialize(endpoint : String? = nil)
      @pipe_ready = Channel(Transport::Inproc::Pipe).new(1)
      super(endpoint)
    end

    def bind(endpoint : String) : self
      scheme, rest = parse_endpoint(endpoint)
      raise UnsupportedTransport.new(scheme) unless scheme == "inproc"
      listener = Transport::Inproc.bind(rest)
      @listener = listener
      @endpoint = endpoint
      spawn accept_one(listener)
      self
    end

    def connect(endpoint : String) : self
      scheme, rest = parse_endpoint(endpoint)
      raise UnsupportedTransport.new(scheme) unless scheme == "inproc"
      pipe = Transport::Inproc.connect(rest, capacity: @options.recv_hwm)
      attach_pipe(pipe)
      @endpoint = endpoint
      self
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

    # Chaining alias.
    def <<(msg) : self
      send(msg)
    end

    def receive : Message
      pipe = await_pipe
      pipe.rx.receive
    rescue Channel::ClosedError
      raise ClosedError.new("socket closed while receiving")
    end

    def receive? : Message?
      pipe = await_pipe?
      return nil unless pipe
      pipe.rx.receive?
    end

    def close : Nil
      return if @closed
      @closed = true
      if listener = @listener
        Transport::Inproc.unbind(listener.name)
      end
      @pipe.try(&.close)
      @pipe_ready.close
    end

    private def send_frames(frames : Message) : self
      pipe = await_pipe
      pipe.tx.send(frames)
      self
    rescue Channel::ClosedError
      raise ClosedError.new("socket closed while sending")
    end

    private def await_pipe : Transport::Inproc::Pipe
      if pipe = @pipe
        return pipe
      end
      pipe = @pipe_ready.receive
      @pipe = pipe
      pipe
    end

    private def await_pipe? : Transport::Inproc::Pipe?
      if pipe = @pipe
        return pipe
      end
      pipe = @pipe_ready.receive?
      @pipe = pipe if pipe
      pipe
    end

    private def attach_pipe(pipe : Transport::Inproc::Pipe) : Nil
      @pipe_ready.send(pipe)
    rescue Channel::ClosedError
      pipe.close
    end

    private def accept_one(listener : Transport::Inproc::Listener) : Nil
      if pipe = listener.incoming.receive?
        attach_pipe(pipe)
      end
    end
  end
end
