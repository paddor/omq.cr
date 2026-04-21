module OMQ
  # DEALER: async REQ. Work-stealing send across peers, fair-queue receive.
  # No envelope manipulation.
  class DEALER < Socket
    @@default_action = :connect

    SOCKET_TYPE = "DEALER"

    @strategy : Routing::Dealer

    def initialize(endpoint : String? = nil)
      @strategy = Routing::Dealer.new(Options::DEFAULT_HWM, Options::DEFAULT_HWM)
      super(endpoint)
    end

    protected def on_commit_options : Nil
      @strategy.commit_capacity(@options.send_hwm, @options.recv_hwm)
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
    @@default_action = :bind

    SOCKET_TYPE = "ROUTER"

    @strategy : Routing::Router

    def initialize(endpoint : String? = nil)
      @strategy = Routing::Router.new(Options::DEFAULT_HWM, Options::DEFAULT_HWM)
      super(endpoint)
    end

    protected def on_commit_options : Nil
      @strategy.commit_capacity(@options.send_hwm, @options.recv_hwm)
    end

    def send(msg : Array(Bytes)) : self
      send_frames(msg)
    end

    def send(msg : Array(String)) : self
      send_frames(msg.map(&.to_slice))
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
  end
end
