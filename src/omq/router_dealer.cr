module OMQ
  # DEALER: async REQ. Work-stealing send across peers, fair-queue receive.
  # No envelope manipulation.
  class DEALER < Socket
    include QueueReadable
    include QueueWritable
    include TryReadable
    include MultipartTryWritable

    @@default_action = :connect

    SOCKET_TYPE = "DEALER"

    @strategy : Routing::Dealer

    def initialize(endpoint : String? = nil, **opts)
      @strategy = Routing::Dealer.new(Options::DEFAULT_HWM, Options::DEFAULT_HWM)
      super(endpoint, **opts)
    end

    protected def on_commit_options : Nil
      @strategy.commit_capacity(@options.send_capacity, @options.recv_capacity, @options.conflate)
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

  # ROUTER: async REP. On receive, prepends the originating peer's
  # identity as the first frame. On send, the first frame selects the
  # target peer by identity.
  class ROUTER < Socket
    include QueueReadable
    include QueueWritable
    include TryReadable

    @@default_action = :bind

    SOCKET_TYPE = "ROUTER"

    @strategy : Routing::Router

    def initialize(endpoint : String? = nil, **opts)
      @strategy = Routing::Router.new(Options::DEFAULT_HWM, Options::DEFAULT_HWM)
      super(endpoint, **opts)
    end

    protected def on_commit_options : Nil
      @strategy.commit_capacity(@options.send_capacity, @options.recv_capacity)
    end

    def send(msg : Array(Bytes)) : self
      send_frames(msg)
    end

    def send(msg : Array(String)) : self
      send_frames(msg.map(&.to_slice))
    end

    def try_send(msg : Array(Bytes)) : Bool
      try_send_frames(msg)
    end

    def try_send(msg : Array(String)) : Bool
      try_send_frames(msg.map(&.to_slice))
    end

    def send_to(identity : String, msg) : self
      send_to(identity.to_slice, msg)
    end

    def send_to(identity : Bytes, msg : String) : self
      send_to_frames(identity, [msg.to_slice])
    end

    def send_to(identity : Bytes, msg : Bytes) : self
      send_to_frames(identity, [msg])
    end

    def send_to(identity : Bytes, msg : Array(String)) : self
      send_to_frames(identity, msg.map(&.to_slice))
    end

    def send_to(identity : Bytes, msg : Array(Bytes)) : self
      send_to_frames(identity, msg)
    end

    def try_send_to(identity : String, msg) : Bool
      try_send_to(identity.to_slice, msg)
    end

    def try_send_to(identity : Bytes, msg : String) : Bool
      try_send_to_frames(identity, [msg.to_slice])
    end

    def try_send_to(identity : Bytes, msg : Bytes) : Bool
      try_send_to_frames(identity, [msg])
    end

    def try_send_to(identity : Bytes, msg : Array(String)) : Bool
      try_send_to_frames(identity, msg.map(&.to_slice))
    end

    def try_send_to(identity : Bytes, msg : Array(Bytes)) : Bool
      try_send_to_frames(identity, msg)
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
      raise ArgumentError.new("ROUTER messages need at least a routing identity frame") if frames.empty?
      if @options.router_mandatory? && @strategy.route?(frames[0]).nil?
        raise Error.new("no route to identity #{frames[0].inspect}")
      end
      channel_send(@strategy.tx, frames)
      self
    rescue Channel::ClosedError
      raise ClosedError.new("socket closed while sending")
    end

    private def try_send_frames(frames : Message) : Bool
      raise ArgumentError.new("ROUTER messages need at least a routing identity frame") if frames.empty?
      if @strategy.route?(frames[0]).nil?
        raise Error.new("no route to identity #{frames[0].inspect}") if @options.router_mandatory?
        return true
      end
      channel_try_send(@strategy.tx, frames)
    end

    private def send_to_frames(identity : Bytes, body : Message) : self
      frames = Message.new(body.size + 2)
      frames << identity.dup
      frames << Bytes.empty
      body.each { |frame| frames << frame }
      send_frames(frames)
    end

    private def try_send_to_frames(identity : Bytes, body : Message) : Bool
      frames = Message.new(body.size + 2)
      frames << identity.dup
      frames << Bytes.empty
      body.each { |frame| frames << frame }
      try_send_frames(frames)
    end
  end
end
