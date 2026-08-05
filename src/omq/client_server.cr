require "../omq"
require "./routing/client"
require "./routing/server"

module OMQ
  # CLIENT (draft, ZeroMQ RFC 41): asynchronous request socket.
  # Round-robins outgoing messages, fair-queues replies. No REQ-style
  # strict alternation, no envelope frames. Single-frame messages.
  class CLIENT < Socket
    include QueueReadable
    include QueueWritable
    include TryReadable
    include SingleFrameTryWritable

    @@default_action = :connect

    SOCKET_TYPE = "CLIENT"

    @strategy : Routing::Client

    def initialize(endpoint : String? = nil, **opts)
      @strategy = Routing::Client.new(Options::DEFAULT_HWM, Options::DEFAULT_HWM)
      super(endpoint, **opts)
    end

    def send(msg : String) : self
      send_frames([msg.to_slice])
    end

    def send(msg : Bytes) : self
      send_frames([msg])
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

    protected def on_commit_options : Nil
      @strategy.commit_capacity(@options.send_capacity, @options.recv_capacity)
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

  # SERVER (draft, ZeroMQ RFC 41): asynchronous reply socket. Uses the
  # CLIENT identity as the routing ID when present, otherwise assigns a
  # 4-byte ID. #receive surfaces the ID as the first frame; #send_to
  # replies to a specific peer by ID.
  class SERVER < Socket
    include QueueReadable
    include TryReadable

    @@default_action = :bind

    SOCKET_TYPE = "SERVER"

    @strategy : Routing::Server

    def initialize(endpoint : String? = nil, **opts)
      @strategy = Routing::Server.new(Options::DEFAULT_HWM, Options::DEFAULT_HWM)
      super(endpoint, **opts)
    end

    def send_to(routing_id : Bytes, msg : String) : self
      send_frames([routing_id, msg.to_slice])
    end

    def send_to(routing_id : Bytes, msg : Bytes) : self
      send_frames([routing_id, msg])
    end

    def try_send_to(routing_id : Bytes, msg : String) : Bool
      try_send_frames([routing_id, msg.to_slice])
    end

    def try_send_to(routing_id : Bytes, msg : Bytes) : Bool
      try_send_frames([routing_id, msg])
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

    protected def on_commit_options : Nil
      @strategy.commit_capacity(@options.send_capacity, @options.recv_capacity)
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

    private def try_send_frames(frames : Message) : Bool
      channel_try_send(@strategy.tx, frames)
    end
  end
end
