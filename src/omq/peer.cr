require "../omq"
require "./routing/peer"

module OMQ
  # PEER (draft, ZeroMQ RFC 51): bidirectional multi-peer socket.
  # Each connected peer gets a 4-byte routing ID; #receive surfaces it
  # as the first frame, #send_to addresses a specific peer.
  class PEER < Socket
    @@default_action = :connect


    SOCKET_TYPE = "PEER"


    @strategy : Routing::Peer


    def initialize(endpoint : String? = nil)
      @strategy = Routing::Peer.new(Options::DEFAULT_HWM, Options::DEFAULT_HWM)
      super(endpoint)
    end


    def send_to(routing_id : Bytes, msg : String) : self
      send_frames([routing_id, msg.to_slice])
    end


    def send_to(routing_id : Bytes, msg : Bytes) : self
      send_frames([routing_id, msg])
    end


    # Snapshot of currently-connected peer routing IDs.
    def peer_routing_ids : Array(Bytes)
      @strategy.peer_routing_ids
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
