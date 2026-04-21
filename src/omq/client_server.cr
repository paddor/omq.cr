require "../omq"
require "./routing/client"
require "./routing/server"

module OMQ
  # CLIENT (draft, ZeroMQ RFC 41): asynchronous request socket.
  # Round-robins outgoing messages, fair-queues replies. No REQ-style
  # strict alternation, no envelope frames. Single-frame messages.
  class CLIENT < Socket
    @@default_action = :connect


    SOCKET_TYPE = "CLIENT"


    @strategy : Routing::Client


    def initialize(endpoint : String? = nil)
      @strategy = Routing::Client.new(Options::DEFAULT_HWM, Options::DEFAULT_HWM)
      super(endpoint)
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
      @strategy.commit_capacity(@options.send_hwm, @options.recv_hwm)
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


  # SERVER (draft, ZeroMQ RFC 41): asynchronous reply socket. Assigns a
  # 4-byte routing ID to each connected CLIENT; #receive surfaces the
  # ID as the first frame, #send_to replies to a specific peer by ID.
  class SERVER < Socket
    @@default_action = :bind


    SOCKET_TYPE = "SERVER"


    @strategy : Routing::Server


    def initialize(endpoint : String? = nil)
      @strategy = Routing::Server.new(Options::DEFAULT_HWM, Options::DEFAULT_HWM)
      super(endpoint)
    end


    def send_to(routing_id : Bytes, msg : String) : self
      send_frames([routing_id, msg.to_slice])
    end


    def send_to(routing_id : Bytes, msg : Bytes) : self
      send_frames([routing_id, msg])
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
      @strategy.commit_capacity(@options.send_hwm, @options.recv_hwm)
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
end
