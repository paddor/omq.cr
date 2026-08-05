module OMQ
  # REQ: strict send/receive alternation, work-stealing across peers.
  # Prepends an empty delimiter frame on the wire.
  class REQ < Socket
    include QueueReadable
    include QueueWritable
    include TryReadable
    include MultipartTryWritable

    @@default_action = :connect

    SOCKET_TYPE = "REQ"

    @strategy : Routing::Req

    def initialize(endpoint : String? = nil, **opts)
      @strategy = Routing::Req.new(Options::DEFAULT_HWM, Options::DEFAULT_HWM)
      super(endpoint, **opts)
    end

    protected def on_commit_options : Nil
      @strategy.commit_capacity(@options.send_capacity, @options.recv_capacity)
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
      channel_receive(@strategy.rx)
    rescue Channel::ClosedError
      raise ClosedError.new("socket closed while receiving")
    end

    def receive? : Message?
      @strategy.rx.receive?
    end

    protected def socket_type : String
      SOCKET_TYPE
    end

    protected def attach_pipe(pipe : Pipe) : Nil
      @strategy.attach(pipe)
    end

    protected def on_close : Nil
      @strategy.close
    end

    private def send_frames(frames : Message) : self
      channel_send(@strategy.tx, frames)
      self
    rescue Channel::ClosedError
      raise ClosedError.new("socket closed while sending")
    end
  end

  # REP: strict receive/send alternation; reply is routed back to the
  # pipe the request came from.
  class REP < Socket
    include QueueReadable
    include QueueWritable
    include MultipartTryWritable

    @@default_action = :bind

    SOCKET_TYPE = "REP"

    @strategy : Routing::Rep

    def initialize(endpoint : String? = nil, **opts)
      @strategy = Routing::Rep.new(Options::DEFAULT_HWM, Options::DEFAULT_HWM)
      super(endpoint, **opts)
    end

    protected def on_commit_options : Nil
      @strategy.commit_capacity(@options.send_capacity, @options.recv_capacity)
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
      @strategy.receive(timeout: @options.read_timeout)
    rescue Channel::ClosedError
      raise ClosedError.new("socket closed while receiving")
    end

    def receive? : Message?
      @strategy.receive?
    end

    def try_receive : Message?
      @strategy.try_receive
    end

    def try_recv : Message?
      try_receive
    end

    protected def socket_type : String
      SOCKET_TYPE
    end

    protected def attach_pipe(pipe : Pipe) : Nil
      @strategy.attach(pipe)
    end

    protected def on_close : Nil
      @strategy.close
    end

    private def send_frames(frames : Message) : self
      @strategy.send(frames, timeout: @options.write_timeout)
      self
    rescue Channel::ClosedError
      raise ClosedError.new("socket closed while sending")
    end

    private def try_send_frames(frames : Message) : Bool
      @strategy.try_send(frames)
    rescue Channel::ClosedError
      raise ClosedError.new("socket closed while sending")
    end
  end
end
