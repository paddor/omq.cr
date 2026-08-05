module OMQ
  # STREAM: raw TCP socket. Receives `[identity, data]`; empty `data`
  # marks connect/disconnect notifications. Send `[identity, data]` to
  # write raw bytes to a peer, or empty data to close it.
  class STREAM < Socket
    include QueueReadable
    include QueueWritable

    @@default_action = :connect

    SOCKET_TYPE = "STREAM"

    @strategy : Routing::Stream

    def initialize(endpoint : String? = nil, **opts)
      @strategy = Routing::Stream.new(Options::DEFAULT_HWM, Options::DEFAULT_HWM)
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

    def send_to(identity : String, data : String) : self
      send_to(identity.to_slice, data.to_slice)
    end

    def send_to(identity : String, data : Bytes) : self
      send_to(identity.to_slice, data)
    end

    def send_to(identity : Bytes, data : String) : self
      send_to(identity, data.to_slice)
    end

    def send_to(identity : Bytes, data : Bytes) : self
      send_frames(Message{identity, data})
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

    protected def on_close_send : Nil
      @strategy.close_send
    end

    private def send_frames(frames : Message) : self
      raise ArgumentError.new("STREAM messages must have [identity, data] frames") unless frames.size == 2
      if @strategy.route?(frames[0]).nil?
        raise Error.new("no route to identity #{frames[0].inspect}") if @options.router_mandatory?
        return self
      end
      channel_send(@strategy.tx, frames)
      self
    rescue Channel::ClosedError
      raise ClosedError.new("socket closed while sending")
    end
  end
end
