module OMQ
  # Socket base class. Concrete types (`PAIR`, `PUSH`, `PULL`, ...) subclass
  # this, declare a `SOCKET_TYPE`, and implement `#attach_pipe` to plug
  # themselves into their routing strategy. The base owns endpoint
  # parsing, transport bind/connect, accept loops, and teardown.
  #
  # Endpoint prefix convention:
  # - `@endpoint` → bind
  # - `>endpoint` → connect
  # - plain      → use the subclass default (`default_action`)
  abstract class Socket
    class_property default_action : Symbol = :connect

    getter options : Options
    getter? closed : Bool = false

    @inproc_names = [] of String
    @tcp_listeners = [] of Transport::TCP::Listener
    @pipes = [] of Pipe

    def initialize(endpoint : String? = nil)
      @options = Options.new
      attach(endpoint) if endpoint
    end

    def self.bind(endpoint : String) : self
      new("@#{endpoint}")
    end

    def self.connect(endpoint : String) : self
      new(">#{endpoint}")
    end

    def attach(endpoint : String) : self
      case endpoint[0]?
      when '@'
        bind(endpoint[1..])
      when '>'
        connect(endpoint[1..])
      else
        case self.class.default_action
        when :bind    then bind(endpoint)
        when :connect then connect(endpoint)
        else raise InvalidEndpoint.new("unknown default action")
        end
      end
      self
    end

    def bind(endpoint : String) : self
      scheme, rest = parse_endpoint(endpoint)
      case scheme
      when "inproc"
        listener = Transport::Inproc.bind(rest)
        @inproc_names << rest
        spawn accept_inproc(listener)
      when "tcp"
        listener = Transport::TCP.bind(endpoint)
        @tcp_listeners << listener
        spawn accept_tcp(listener)
      else
        raise UnsupportedTransport.new(scheme)
      end
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
                 local_socket_type: socket_type,
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
      register_pipe(pipe)
      self
    end

    def close : Nil
      return if @closed
      @closed = true
      @inproc_names.each { |n| Transport::Inproc.unbind(n) }
      @tcp_listeners.each(&.close)
      @pipes.each(&.close)
      on_close
    end

    # Last-bound TCP port, or `nil` if not bound over TCP.
    def port : Int32?
      @tcp_listeners.first?.try(&.port)
    end

    # Subclasses override to wire each pipe into their routing strategy.
    protected abstract def attach_pipe(pipe : Pipe) : Nil

    # ZMTP socket-type string for the READY command. Concrete types override.
    protected abstract def socket_type : String

    # Subclasses override to tear down their strategy.
    protected def on_close : Nil
    end

    protected def parse_endpoint(endpoint : String) : {String, String}
      idx = endpoint.index("://") || raise InvalidEndpoint.new("missing scheme: #{endpoint}")
      {endpoint[0...idx], endpoint[idx + 3..]}
    end

    private def register_pipe(pipe : Pipe) : Nil
      if @closed
        pipe.close
        return
      end
      @pipes << pipe
      attach_pipe(pipe)
    end

    private def accept_inproc(listener : Transport::Inproc::Listener) : Nil
      while pipe = listener.incoming.receive?
        break if @closed
        register_pipe(pipe)
      end
    end

    private def accept_tcp(listener : Transport::TCP::Listener) : Nil
      loop do
        tcp = listener.accept
        break unless tcp
        break if @closed
        begin
          pipe = Transport::TCP.adopt(
            tcp,
            local_socket_type: socket_type,
            local_identity: @options.identity,
            as_server: true,
            send_capacity: @options.send_hwm,
            recv_capacity: @options.recv_hwm,
            mechanism: @options.mechanism,
            max_message_size: @options.max_message_size,
          )
          register_pipe(pipe)
        rescue IO::Error | ProtocolError
          # handshake failed; keep accepting
        end
      end
    end

    delegate send_hwm, recv_hwm, linger, identity,
      read_timeout, write_timeout, recv_timeout, send_timeout,
      reconnect_interval, heartbeat_interval, heartbeat_ttl, heartbeat_timeout,
      max_message_size, sndbuf, rcvbuf, on_mute, conflate,
      router_mandatory?, to: @options

    {% for m in %w(send_hwm recv_hwm linger identity read_timeout write_timeout
                   recv_timeout send_timeout reconnect_interval heartbeat_interval
                   heartbeat_ttl heartbeat_timeout max_message_size sndbuf rcvbuf
                   on_mute conflate router_mandatory) %}
      def {{m.id}}=(val)
        @options.{{m.id}} = val
      end
    {% end %}
  end
end
