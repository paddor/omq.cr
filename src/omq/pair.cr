module OMQ
  # PAIR socket: exactly one peer, bidirectional, preserves message
  # boundaries. Works over inproc and TCP.
  class PAIR < Socket
    @@default_action = :bind

    SOCKET_TYPE = "PAIR"

    getter endpoint : String?
    getter? bound : Bool = false

    @pipe : Pipe?
    @pipe_ready : Channel(Pipe)

    # Track transport-specific state so `close` can tear it down.
    @inproc_name : String?
    @tcp_listener : Transport::TCP::Listener?

    def initialize(endpoint : String? = nil)
      @pipe_ready = Channel(Pipe).new(1)
      super(endpoint)
    end

    def bind(endpoint : String) : self
      scheme, rest = parse_endpoint(endpoint)
      case scheme
      when "inproc"
        listener = Transport::Inproc.bind(rest)
        @inproc_name = rest
        spawn accept_one_inproc(listener)
      when "tcp"
        listener = Transport::TCP.bind(endpoint)
        @tcp_listener = listener
        rest_with_port = "#{scheme}://#{rest.sub(/:0$/, ":#{listener.port}")}"
        spawn accept_one_tcp(listener)
        endpoint = rest_with_port
      else
        raise UnsupportedTransport.new(scheme)
      end
      @endpoint = endpoint
      @bound = true
      self
    end

    def connect(endpoint : String) : self
      scheme, rest = parse_endpoint(endpoint)
      pipe = case scheme
             when "inproc"
               Transport::Inproc.connect(rest, capacity: @options.recv_hwm)
             when "tcp"
               tcp = Transport::TCP.connect(endpoint)
               Transport::TCP.adopt(
                 tcp,
                 local_socket_type: SOCKET_TYPE,
                 local_identity: @options.identity,
                 as_server: false,
                 send_capacity: @options.send_hwm,
                 recv_capacity: @options.recv_hwm,
                 mechanism: @options.mechanism,
                 max_message_size: @options.max_message_size,
               )
             else
               raise UnsupportedTransport.new(scheme)
             end
      attach_pipe(pipe)
      @endpoint = endpoint
      self
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
      pipe = await_pipe
      pipe.rx.receive
    rescue Channel::ClosedError
      raise ClosedError.new("socket closed while receiving")
    end

    def receive? : Message?
      pipe = await_pipe?
      return nil unless pipe
      pipe.rx.receive?
    end

    # Last-bound port for TCP listeners. `nil` if not bound over TCP.
    def port : Int32?
      @tcp_listener.try(&.port)
    end

    def close : Nil
      return if @closed
      @closed = true
      if name = @inproc_name
        Transport::Inproc.unbind(name)
      end
      @tcp_listener.try(&.close)
      @pipe.try(&.close)
      @pipe_ready.close
    end

    private def send_frames(frames : Message) : self
      pipe = await_pipe
      pipe.tx.send(frames)
      self
    rescue Channel::ClosedError
      raise ClosedError.new("socket closed while sending")
    end

    private def await_pipe : Pipe
      if pipe = @pipe
        return pipe
      end
      pipe = @pipe_ready.receive
      @pipe = pipe
      pipe
    end

    private def await_pipe? : Pipe?
      if pipe = @pipe
        return pipe
      end
      pipe = @pipe_ready.receive?
      @pipe = pipe if pipe
      pipe
    end

    private def attach_pipe(pipe : Pipe) : Nil
      @pipe_ready.send(pipe)
    rescue Channel::ClosedError
      pipe.close
    end

    private def accept_one_inproc(listener : Transport::Inproc::Listener) : Nil
      if pipe = listener.incoming.receive?
        attach_pipe(pipe)
      end
    end

    private def accept_one_tcp(listener : Transport::TCP::Listener) : Nil
      tcp = listener.accept
      return unless tcp
      pipe = Transport::TCP.adopt(
        tcp,
        local_socket_type: SOCKET_TYPE,
        local_identity: @options.identity,
        as_server: true,
        send_capacity: @options.send_hwm,
        recv_capacity: @options.recv_hwm,
        mechanism: @options.mechanism,
        max_message_size: @options.max_message_size,
      )
      attach_pipe(pipe)
    rescue ex : IO::Error | ProtocolError
      # handshake failed — listener fiber dies quietly
    end
  end
end
