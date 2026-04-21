require "../omq"
require "./routing/radio"
require "./routing/dish"

module OMQ
  # RADIO (draft, ZeroMQ RFC 48): group-based publisher. Every message
  # is a 2-frame `[group, body]`. v0.1 broadcasts to every peer and
  # leaves group-filtering to DISH.
  class RADIO < Socket
    @@default_action = :bind


    SOCKET_TYPE = "RADIO"


    @strategy : Routing::Radio


    def initialize(endpoint : String? = nil)
      @strategy = Routing::Radio.new(Options::DEFAULT_HWM)
      super(endpoint)
    end


    def publish(group : String, body : String) : self
      send_frames([group.to_slice, body.to_slice])
    end


    def publish(group : String, body : Bytes) : self
      send_frames([group.to_slice, body])
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
    rescue ::Channel::ClosedError
      raise ClosedError.new("socket closed while sending")
    end
  end


  # DISH (draft, ZeroMQ RFC 48): group-based subscriber. #join selects
  # the groups to receive; messages for other groups are dropped.
  class DISH < Socket
    @@default_action = :connect


    SOCKET_TYPE = "DISH"


    @strategy : Routing::Dish


    def initialize(endpoint : String? = nil)
      @strategy = Routing::Dish.new(Options::DEFAULT_HWM)
      super(endpoint)
    end


    def join(group : String) : self
      @strategy.join(group)
      self
    end


    def leave(group : String) : self
      @strategy.leave(group)
      self
    end


    def receive : Message
      channel_receive(@strategy.rx)
    rescue ::Channel::ClosedError
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
  end
end
