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
    @ipc_listeners = [] of Transport::IPC::Listener
    @pipes = [] of Pipe
    @committed = false
    @shutdown = Channel(Nil).new

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
      commit_options
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
      when "ipc"
        listener = Transport::IPC.bind(endpoint)
        @ipc_listeners << listener
        spawn accept_ipc(listener)
      else
        raise UnsupportedTransport.new(scheme)
      end
      self
    end

    def connect(endpoint : String) : self
      commit_options
      scheme, rest = parse_endpoint(endpoint)
      case scheme
      when "inproc"
        pipe = Transport::Inproc.connect(rest, capacity: @options.recv_hwm, local_identity: @options.identity)
        register_pipe(pipe)
      when "tcp", "ipc"
        # First attempt synchronously so a happy-path connect gives the
        # caller a usable pipe before returning. On failure, hand off to
        # the retry loop in the background.
        begin
          pipe = dial(scheme, endpoint)
          register_pipe(pipe)
          spawn supervise_pipe(pipe, scheme, endpoint)
        rescue IO::Error | ProtocolError
          spawn connection_manager(scheme, endpoint, initial_delay: nil)
        end
      else
        raise UnsupportedTransport.new(scheme)
      end
      self
    end

    def close : Nil
      return if @closed
      @closed = true
      @shutdown.close
      @inproc_names.each { |n| Transport::Inproc.unbind(n) }
      @tcp_listeners.each(&.close)
      @ipc_listeners.each(&.close)
      drain_for_linger(@options.linger)
      @pipes.each(&.close)
      on_close
    end

    # Supervises an already-attached pipe: waits until it terminates
    # (peer gone, handshake torn down) and starts the reconnect loop.
    private def supervise_pipe(pipe : Pipe, scheme : String, endpoint : String) : Nil
      pipe.await_closed
      return if @closed
      @pipes.delete(pipe)
      connection_manager(scheme, endpoint, initial_delay: nil)
    end

    # Retry loop for TCP/IPC: keeps dialing (with `reconnect_interval`
    # backoff) until a pipe succeeds, then supervises that pipe and loops
    # back. Exits when the socket is closed.
    private def connection_manager(scheme : String, endpoint : String, initial_delay : Time::Span?) : Nil
      delay_hint = initial_delay
      until @closed
        delay_hint = next_reconnect_delay(delay_hint)
        break unless sleep_with_shutdown(delay_hint)
        break if @closed
        begin
          pipe = dial(scheme, endpoint)
        rescue IO::Error | ProtocolError
          next
        end
        register_pipe(pipe)
        pipe.await_closed
        break if @closed
        @pipes.delete(pipe)
        delay_hint = nil
      end
    end

    private def dial(scheme : String, endpoint : String) : Pipe
      case scheme
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
          heartbeat_interval: @options.heartbeat_interval,
          heartbeat_ttl: @options.heartbeat_ttl,
          heartbeat_timeout: @options.heartbeat_timeout,
          sndbuf: @options.sndbuf,
          rcvbuf: @options.rcvbuf,
        )
      when "ipc"
        unix = Transport::IPC.connect(endpoint)
        Transport::IPC.adopt(
          unix,
          local_socket_type: socket_type,
          local_identity: @options.identity,
          as_server: false,
          send_capacity: @options.send_hwm,
          recv_capacity: @options.recv_hwm,
          mechanism: @options.mechanism,
          max_message_size: @options.max_message_size,
          heartbeat_interval: @options.heartbeat_interval,
          heartbeat_ttl: @options.heartbeat_ttl,
          heartbeat_timeout: @options.heartbeat_timeout,
          sndbuf: @options.sndbuf,
          rcvbuf: @options.rcvbuf,
        )
      else
        raise UnsupportedTransport.new(scheme)
      end
    end

    # Current reconnect delay. First failure → `ri.begin` (or the fixed
    # span). Subsequent failures double up to `ri.end` when configured
    # as a range.
    private def next_reconnect_delay(prev : Time::Span?) : Time::Span
      ri = @options.reconnect_interval
      case ri
      in Time::Span
        ri
      in Range(Time::Span, Time::Span)
        return ri.begin if prev.nil? || prev < ri.begin
        doubled = prev * 2
        doubled > ri.end ? ri.end : doubled
      end
    end

    # Sleep for `span`, or return early if the socket is closed. Returns
    # `true` if the full span elapsed, `false` if interrupted by close.
    private def sleep_with_shutdown(span : Time::Span) : Bool
      select
      when @shutdown.receive?
        false
      when timeout(span)
        true
      end
    end

    # Two-phase drain so in-flight sends reach the wire before teardown.
    # linger=0 skips drain entirely (current fast-path); nil waits forever;
    # anything else splits the budget between the routing-strategy pumps
    # and the per-pipe write pumps.
    private def drain_for_linger(linger : Time::Span?) : Nil
      return if linger == 0.seconds
      on_close_send
      deadline = linger ? Time.instant + linger : nil
      await_strategy_drain(remaining(deadline))
      @pipes.each(&.close_send)
      @pipes.each { |p| p.await_drained(remaining(deadline)) }
    end

    private def remaining(deadline : Time::Instant?) : Time::Span?
      return nil unless deadline
      left = deadline - Time.instant
      left.positive? ? left : 0.seconds
    end

    # Last-bound TCP port, or `nil` if not bound over TCP.
    def port : Int32?
      @tcp_listeners.first?.try(&.port)
    end

    # Number of live pipes — a rough peer count useful for benches and tests
    # that want to wait until a handshake has completed.
    def peer_count : Int32
      @pipes.count { |p| !p.closed? }
    end

    # Send `msg` on `channel`, raising `IO::TimeoutError` if the socket's
    # `write_timeout` elapses first. `nil` timeout = block forever.
    protected def channel_send(channel : Channel(Message), msg : Message) : Nil
      if span = @options.write_timeout
        select
        when channel.send(msg)
        when timeout(span)
          raise IO::TimeoutError.new("send timed out after #{span}")
        end
      else
        channel.send(msg)
      end
    end

    # Receive from `channel`, raising `IO::TimeoutError` if the socket's
    # `read_timeout` elapses first. `nil` timeout = block forever.
    protected def channel_receive(channel : Channel(Message)) : Message
      if span = @options.read_timeout
        select
        when msg = channel.receive
          msg
        when timeout(span)
          raise IO::TimeoutError.new("receive timed out after #{span}")
        end
      else
        channel.receive
      end
    end

    # Subclasses override to wire each pipe into their routing strategy.
    protected abstract def attach_pipe(pipe : Pipe) : Nil

    # ZMTP socket-type string for the READY command. Concrete types override.
    protected abstract def socket_type : String

    # Subclasses override to tear down their strategy.
    protected def on_close : Nil
    end

    # Subclasses override to stop their strategy from accepting new
    # sends, without tearing down queues that linger still needs.
    protected def on_close_send : Nil
    end

    # Subclasses with a send-side strategy override to expose its drain.
    protected def await_strategy_drain(span : Time::Span?) : Nil
    end

    # Runs once, on the first bind/connect. Subclasses rebuild their
    # strategy channels here using the finalized `@options` (e.g. HWMs),
    # so `socket.send_hwm = 1` between `.new` and `.bind` actually takes
    # effect.
    protected def on_commit_options : Nil
    end

    private def commit_options : Nil
      return if @committed
      @committed = true
      on_commit_options
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
            heartbeat_interval: @options.heartbeat_interval,
            heartbeat_ttl: @options.heartbeat_ttl,
            heartbeat_timeout: @options.heartbeat_timeout,
            sndbuf: @options.sndbuf,
            rcvbuf: @options.rcvbuf,
          )
          register_pipe(pipe)
        rescue IO::Error | ProtocolError
          # handshake failed; keep accepting
        end
      end
    end

    private def accept_ipc(listener : Transport::IPC::Listener) : Nil
      loop do
        unix = listener.accept
        break unless unix
        break if @closed
        begin
          pipe = Transport::IPC.adopt(
            unix,
            local_socket_type: socket_type,
            local_identity: @options.identity,
            as_server: true,
            send_capacity: @options.send_hwm,
            recv_capacity: @options.recv_hwm,
            mechanism: @options.mechanism,
            max_message_size: @options.max_message_size,
            heartbeat_interval: @options.heartbeat_interval,
            heartbeat_ttl: @options.heartbeat_ttl,
            heartbeat_timeout: @options.heartbeat_timeout,
            sndbuf: @options.sndbuf,
            rcvbuf: @options.rcvbuf,
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
