module OMQ
  # PUB: write-only, fans out every message to every connected SUB peer.
  class PUB < Socket
    @@default_action = :bind

    SOCKET_TYPE = "PUB"

    @strategy : Routing::Pub

    def initialize(endpoint : String? = nil)
      @strategy = Routing::Pub.new(Options::DEFAULT_HWM)
      super(endpoint)
    end

    protected def on_commit_options : Nil
      @strategy.commit_capacity(@options.send_hwm, @options.recv_hwm, @options.conflate, @options.on_mute)
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


  # XPUB: like PUB, but subscribe/cancel messages sent by XSUB peers
  # surface on `#receive` as raw data frames (first byte 0x01 = subscribe,
  # 0x00 = cancel; ZMTP 3.0 legacy encoding). No server-side filtering in
  # v0.1 — every published message reaches every peer.
  class XPUB < Socket
    @@default_action = :bind

    SOCKET_TYPE = "XPUB"

    @strategy : Routing::XPub

    def initialize(endpoint : String? = nil)
      @strategy = Routing::XPub.new(Options::DEFAULT_HWM)
      super(endpoint)
    end

    protected def on_commit_options : Nil
      @strategy.commit_capacity(@options.send_hwm, @options.recv_hwm, @options.conflate, @options.on_mute)
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


  # XSUB: read/write. `#send` broadcasts to every connected peer (so an
  # app can issue subscribe/cancel to all upstream XPUBs at once).
  # `#receive` returns every incoming message — no local prefix filter.
  # `#subscribe(prefix)` / `#unsubscribe(prefix)` are convenience helpers
  # that send the ZMTP-3.0-style `\x01 + prefix` / `\x00 + prefix` frames.
  class XSUB < Socket
    @@default_action = :connect

    SOCKET_TYPE = "XSUB"

    @strategy : Routing::XSub

    def initialize(endpoint : String? = nil)
      @strategy = Routing::XSub.new(Options::DEFAULT_HWM)
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

    def subscribe(prefix : String = "") : self
      subscribe(prefix.to_slice)
    end

    def subscribe(prefix : Bytes) : self
      send_frames([prefix_frame(0x01_u8, prefix)])
    end

    def unsubscribe(prefix : String) : self
      unsubscribe(prefix.to_slice)
    end

    def unsubscribe(prefix : Bytes) : self
      send_frames([prefix_frame(0x00_u8, prefix)])
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

    private def prefix_frame(marker : UInt8, prefix : Bytes) : Bytes
      frame = Bytes.new(prefix.size + 1)
      frame[0] = marker
      prefix.copy_to(frame + 1) if prefix.size > 0
      frame
    end
  end


  # SUB: read-only; only messages whose first frame matches a subscribed
  # prefix are surfaced to the app.
  class SUB < Socket
    @@default_action = :connect

    SOCKET_TYPE = "SUB"

    @strategy : Routing::Sub

    def initialize(endpoint : String? = nil)
      @strategy = Routing::Sub.new(Options::DEFAULT_HWM)
      super(endpoint)
    end

    protected def on_commit_options : Nil
      @strategy.commit_capacity(@options.send_hwm, @options.recv_hwm)
    end

    def subscribe(prefix : String = "") : self
      @strategy.subscribe(prefix.to_slice)
      self
    end

    def subscribe(prefix : Bytes) : self
      @strategy.subscribe(prefix)
      self
    end

    def unsubscribe(prefix : String) : self
      @strategy.unsubscribe(prefix.to_slice)
      self
    end

    def unsubscribe(prefix : Bytes) : self
      @strategy.unsubscribe(prefix)
      self
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
