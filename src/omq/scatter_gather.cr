require "../omq"
require "./routing/scatter"
require "./routing/gather"

module OMQ
  # SCATTER (draft, ZeroMQ RFC 49): pipeline sender that round-robins to
  # GATHER peers. Single-frame messages only.
  class SCATTER < Socket
    @@default_action = :connect


    SOCKET_TYPE = "SCATTER"


    @strategy : Routing::Scatter


    def initialize(endpoint : String? = nil)
      @strategy = Routing::Scatter.new(Options::DEFAULT_HWM)
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


    protected def socket_type : String
      SOCKET_TYPE
    end


    protected def on_commit_options : Nil
      @strategy.commit_capacity(@options.send_hwm, @options.recv_hwm)
    end


    protected def attach_pipe(pipe : Pipe) : Nil
      @strategy.attach(pipe)
    end


    protected def on_close_send : Nil
      @strategy.close_send
    end


    protected def await_strategy_drain(span : Time::Span?) : Nil
      @strategy.await_drained(span)
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


  # GATHER (draft, ZeroMQ RFC 49): pipeline receiver that fair-queues
  # from SCATTER peers. Single-frame messages only.
  class GATHER < Socket
    @@default_action = :bind


    SOCKET_TYPE = "GATHER"


    @strategy : Routing::Gather


    def initialize(endpoint : String? = nil)
      @strategy = Routing::Gather.new(Options::DEFAULT_HWM)
      super(endpoint)
    end


    protected def on_commit_options : Nil
      @strategy.commit_capacity(@options.send_hwm, @options.recv_hwm)
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
  end
end
