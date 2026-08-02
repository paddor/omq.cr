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
    @closed = false

    @inproc_names = [] of String
    @tcp_listeners = [] of Transport::TCP::Listener
    @ipc_listeners = [] of Transport::IPC::Listener
    @bound_endpoints = [] of String
    @disabled_connect_endpoints = [] of String
    @pipe_endpoints = {} of Pipe => String
    @pipes = [] of Pipe
    @committed = false
    @state_mutex = Mutex.new
    @shutdown = Channel(Nil).new
    @monitor : Channel(MonitorEvent)? = nil

    private struct UnsetOption
    end

    UNSET = UnsetOption.new

    def initialize(endpoint : String? = nil, **opts)
      @options = Options.new
      @options.on_mute = default_on_mute
      apply_options(**opts)
      attach(endpoint) if endpoint
    end

    def self.bind(endpoint : String, **opts) : self
      new("@#{endpoint}", **opts)
    end

    def self.connect(endpoint : String, **opts) : self
      new(">#{endpoint}", **opts)
    end

    def closed? : Bool
      @state_mutex.synchronize { @closed }
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
        else               raise InvalidEndpoint.new("unknown default action")
        end
      end
      self
    end

    def bind(endpoint : String) : self
      ensure_open!
      commit_options
      scheme, rest = parse_endpoint(endpoint)
      case scheme
      when "inproc"
        listener = Transport::Inproc.bind(rest)
        begin
          track_inproc_listener(rest, endpoint)
        rescue ex : ClosedError
          Transport::Inproc.unbind(rest)
          listener.close
          raise ex
        end
        emit_monitor(MonitorEvent::Kind::Listening, endpoint)
        spawn accept_inproc(listener, endpoint)
      when "tcp"
        listener = Transport::TCP.bind(endpoint)
        begin
          track_tcp_listener(listener)
        rescue ex : ClosedError
          listener.close
          raise ex
        end
        emit_monitor(MonitorEvent::Kind::Listening, listener.endpoint)
        spawn accept_tcp(listener, listener.endpoint)
      when "ipc"
        listener = Transport::IPC.bind(endpoint)
        begin
          track_ipc_listener(listener)
        rescue ex : ClosedError
          listener.close
          raise ex
        end
        emit_monitor(MonitorEvent::Kind::Listening, endpoint)
        spawn accept_ipc(listener, endpoint)
      else
        raise UnsupportedTransport.new(scheme)
      end
      self
    end

    def connect(endpoint : String) : self
      ensure_open!
      commit_options
      enable_connect_endpoint(endpoint)
      scheme, rest = parse_endpoint(endpoint)
      case scheme
      when "inproc"
        pipe = Transport::Inproc.connect(rest, capacity: @options.recv_capacity, local_identity: @options.identity)
        if register_pipe(pipe, endpoint)
          emit_monitor(MonitorEvent::Kind::Connected, endpoint, pipe)
          spawn watch_pipe_close(pipe, endpoint)
        end
      when "tcp", "ipc"
        # First attempt synchronously so a happy-path connect gives the
        # caller a usable pipe before returning. On failure, hand off to
        # the retry loop in the background.
        begin
          pipe = dial(scheme, endpoint)
          if register_pipe(pipe, endpoint)
            emit_monitor(MonitorEvent::Kind::Connected, endpoint, pipe)
            spawn supervise_pipe(pipe, scheme, endpoint)
          end
        rescue err : IO::Error | ProtocolError
          emit_monitor(MonitorEvent::Kind::ConnectDelayed, endpoint, error: err)
          spawn connection_manager(scheme, endpoint, initial_delay: nil)
        end
      else
        raise UnsupportedTransport.new(scheme)
      end
      self
    end

    def disconnect(endpoint : String) : self
      return self if closed?
      parse_endpoint(endpoint)
      disable_connect_endpoint(endpoint)
      close_pipes_at(endpoint)
      self
    end

    def unbind(endpoint : String) : self
      return self if closed?
      scheme, rest = parse_endpoint(endpoint)
      case scheme
      when "inproc"
        Transport::Inproc.unbind(rest)
        @inproc_names.delete(rest)
        @bound_endpoints.delete(endpoint)
        close_pipes_at(endpoint)
      when "tcp"
        close_matching_tcp_listeners(endpoint)
      when "ipc"
        close_matching_ipc_listeners(endpoint)
      else
        raise UnsupportedTransport.new(scheme)
      end
      self
    end

    def set_unbounded : self
      @options.send_hwm = nil
      @options.recv_hwm = nil
      self
    end

    def close : Nil
      inproc_names, tcp_listeners, ipc_listeners, pipes = @state_mutex.synchronize do
        return if @closed
        @closed = true
        @shutdown.close unless @shutdown.closed?

        inproc_snapshot = @inproc_names.dup
        tcp_snapshot = @tcp_listeners.dup
        ipc_snapshot = @ipc_listeners.dup
        pipe_snapshot = @pipes.dup

        @inproc_names.clear
        @tcp_listeners.clear
        @ipc_listeners.clear
        @bound_endpoints.clear
        @disabled_connect_endpoints.clear
        @pipe_endpoints.clear
        @pipes.clear

        {inproc_snapshot, tcp_snapshot, ipc_snapshot, pipe_snapshot}
      end

      inproc_names.each { |n| Transport::Inproc.unbind(n) }
      tcp_listeners.each(&.close)
      ipc_listeners.each(&.close)
      drain_for_linger(@options.linger, pipes)
      pipes.each(&.close)
      emit_monitor(MonitorEvent::Kind::Closed, "")
      @monitor.try(&.close)
      on_close
    end

    def inspect(io : IO) : Nil
      bound = @state_mutex.synchronize { @bound_endpoints.dup }
      io << "#<" << self.class.name << " bound=" << bound.inspect << ">"
    end

    # Connection lifecycle subscription. Lazily creates a buffered channel
    # on first access; drop-on-full semantics so a slow subscriber never
    # stalls the socket. The channel is closed when the socket closes, so
    # subscribers can iterate with `while ev = socket.monitor.receive?`.
    def monitor(capacity : Int32 = 128) : Channel(MonitorEvent)
      @state_mutex.synchronize do
        if ch = @monitor
          ch
        else
          ch = Channel(MonitorEvent).new(capacity)
          ch.close if @closed
          @monitor = ch
          ch
        end
      end
    end

    private def emit_monitor(kind : MonitorEvent::Kind, endpoint : String, pipe : Pipe? = nil, error : Exception? = nil) : Nil
      ch = @monitor
      return unless ch
      return if ch.closed?
      ev = MonitorEvent.new(kind, endpoint, pipe, error)
      select
      when ch.send(ev)
      else
        # drop on full — subscriber too slow
      end
    rescue Channel::ClosedError
    end

    # Supervises an already-attached pipe: waits until it terminates
    # (peer gone, handshake torn down) and starts the reconnect loop.
    private def supervise_pipe(pipe : Pipe, scheme : String, endpoint : String) : Nil
      pipe.await_closed
      return if closed?
      return unless unregister_pipe(pipe)
      emit_monitor(MonitorEvent::Kind::Disconnected, endpoint, pipe)
      return if connect_endpoint_disabled?(endpoint)
      connection_manager(scheme, endpoint, initial_delay: nil)
    end

    # Retry loop for TCP/IPC: keeps dialing (with `reconnect_interval`
    # backoff) until a pipe succeeds, then supervises that pipe and loops
    # back. Exits when the socket is closed.
    private def connection_manager(scheme : String, endpoint : String, initial_delay : Time::Span?) : Nil
      delay_hint = initial_delay
      while connect_endpoint_enabled?(endpoint)
        delay_hint = next_reconnect_delay(delay_hint)
        break unless sleep_with_shutdown(delay_hint)
        break unless connect_endpoint_enabled?(endpoint)
        begin
          pipe = dial(scheme, endpoint)
        rescue err : IO::Error | ProtocolError
          emit_monitor(MonitorEvent::Kind::ConnectRetried, endpoint, error: err)
          next
        end
        next unless register_pipe(pipe, endpoint)
        emit_monitor(MonitorEvent::Kind::Connected, endpoint, pipe)
        pipe.await_closed
        break unless connect_endpoint_enabled?(endpoint)
        next unless unregister_pipe(pipe)
        emit_monitor(MonitorEvent::Kind::Disconnected, endpoint, pipe)
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
          send_capacity: @options.send_capacity,
          recv_capacity: @options.recv_capacity,
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
          send_capacity: @options.send_capacity,
          recv_capacity: @options.recv_capacity,
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
    private def drain_for_linger(linger : Time::Span?, pipes : Array(Pipe)) : Nil
      return if linger == 0.seconds
      on_close_send
      deadline = linger ? Time.instant + linger : nil
      await_strategy_drain(remaining(deadline))
      pipes.each(&.close_send)
      pipes.each { |p| p.await_drained(remaining(deadline)) }
    end

    private def remaining(deadline : Time::Instant?) : Time::Span?
      return nil unless deadline
      left = deadline - Time.instant
      left.positive? ? left : 0.seconds
    end

    # Last-bound TCP port, or `nil` if not bound over TCP.
    def port : Int32?
      @state_mutex.synchronize { @tcp_listeners.first?.try(&.port) }
    end

    # Number of live pipes — a rough peer count useful for benches and tests
    # that want to wait until a handshake has completed.
    def peer_count : Int32
      @state_mutex.synchronize { @pipes.count { |p| !p.closed? } }
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

    protected def default_on_mute : Options::MuteStrategy
      Options::MuteStrategy::Block
    end

    protected def apply_options(
      *,
      send_hwm : Int32 | Nil | UnsetOption = UNSET,
      recv_hwm : Int32 | Nil | UnsetOption = UNSET,
      linger : Time::Span | Nil | UnsetOption = UNSET,
      identity : String | Bytes | Nil = nil,
      read_timeout : Time::Span? = nil,
      write_timeout : Time::Span? = nil,
      recv_timeout : Time::Span? = nil,
      send_timeout : Time::Span? = nil,
      reconnect_interval : Time::Span | Range(Time::Span, Time::Span) | Nil = nil,
      heartbeat_interval : Time::Span? = nil,
      heartbeat_ttl : Time::Span? = nil,
      heartbeat_timeout : Time::Span? = nil,
      max_message_size : Int64? = nil,
      sndbuf : Int32? = nil,
      rcvbuf : Int32? = nil,
      on_mute : Options::MuteStrategy | Symbol | Nil = nil,
      conflate : Bool? = nil,
      mechanism : ZMTP::Mechanism? = nil,
      router_mandatory : Bool? = nil,
    ) : Nil
      @options.send_hwm = send_hwm unless send_hwm.is_a?(UnsetOption)
      @options.recv_hwm = recv_hwm unless recv_hwm.is_a?(UnsetOption)
      @options.linger = linger unless linger.is_a?(UnsetOption)
      @options.identity = identity if identity
      @options.read_timeout = read_timeout if read_timeout
      @options.write_timeout = write_timeout if write_timeout
      @options.recv_timeout = recv_timeout if recv_timeout
      @options.send_timeout = send_timeout if send_timeout
      @options.reconnect_interval = reconnect_interval if reconnect_interval
      @options.heartbeat_interval = heartbeat_interval if heartbeat_interval
      @options.heartbeat_ttl = heartbeat_ttl if heartbeat_ttl
      @options.heartbeat_timeout = heartbeat_timeout if heartbeat_timeout
      @options.max_message_size = max_message_size if max_message_size
      @options.sndbuf = sndbuf if sndbuf
      @options.rcvbuf = rcvbuf if rcvbuf
      @options.on_mute = on_mute if on_mute
      @options.conflate = conflate unless conflate.nil?
      @options.mechanism = mechanism if mechanism
      @options.router_mandatory = router_mandatory unless router_mandatory.nil?
    end

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
      should_commit = @state_mutex.synchronize do
        if @committed
          false
        else
          @committed = true
          true
        end
      end
      on_commit_options if should_commit
    end

    protected def parse_endpoint(endpoint : String) : {String, String}
      idx = endpoint.index("://") || raise InvalidEndpoint.new("missing scheme: #{endpoint}")
      {endpoint[0...idx], endpoint[idx + 3..]}
    end

    private def register_pipe(pipe : Pipe, endpoint : String) : Bool
      should_attach = @state_mutex.synchronize do
        if @closed || pipe.closed? || @disabled_connect_endpoints.includes?(endpoint)
          false
        else
          @pipes << pipe
          @pipe_endpoints[pipe] = endpoint
          true
        end
      end

      unless should_attach
        pipe.close
        return false
      end
      attach_pipe(pipe)
      true
    end

    private def unregister_pipe(pipe : Pipe) : String?
      @state_mutex.synchronize do
        @pipes.delete(pipe)
        @pipe_endpoints.delete(pipe)
      end
    end

    private def enable_connect_endpoint(endpoint : String) : Nil
      @state_mutex.synchronize { @disabled_connect_endpoints.delete(endpoint) }
    end

    private def disable_connect_endpoint(endpoint : String) : Nil
      @state_mutex.synchronize do
        @disabled_connect_endpoints << endpoint unless @disabled_connect_endpoints.includes?(endpoint)
      end
    end

    private def connect_endpoint_disabled?(endpoint : String) : Bool
      @state_mutex.synchronize { @disabled_connect_endpoints.includes?(endpoint) }
    end

    private def connect_endpoint_enabled?(endpoint : String) : Bool
      @state_mutex.synchronize { !@closed && !@disabled_connect_endpoints.includes?(endpoint) }
    end

    private def close_pipes_at(endpoint : String) : Nil
      pipes = detach_pipes_at(endpoint)
      pipes.each do |pipe|
        pipe.close
        emit_monitor(MonitorEvent::Kind::Disconnected, endpoint, pipe)
      end
    end

    private def close_matching_tcp_listeners(endpoint : String) : Nil
      _scheme, rest = parse_endpoint(endpoint)
      _host, port = Transport::TCP.parse_authority(rest)
      listeners = @state_mutex.synchronize do
        matches = @tcp_listeners.select { |listener| listener.endpoint == endpoint || listener.port == port }
        matches.each do |listener|
          @tcp_listeners.delete(listener)
          @bound_endpoints.delete(listener.endpoint)
        end
        matches
      end
      listeners.each do |listener|
        listener.close
        close_pipes_at(listener.endpoint)
      end
    end

    private def close_matching_ipc_listeners(endpoint : String) : Nil
      listeners = @state_mutex.synchronize do
        matches = @ipc_listeners.select { |listener| listener.endpoint == endpoint }
        matches.each do |listener|
          @ipc_listeners.delete(listener)
          @bound_endpoints.delete(listener.endpoint)
        end
        matches
      end
      listeners.each do |listener|
        listener.close
        close_pipes_at(listener.endpoint)
      end
    end

    private def detach_pipes_at(endpoint : String) : Array(Pipe)
      @state_mutex.synchronize do
        pipes = @pipes.select { |pipe| @pipe_endpoints[pipe]? == endpoint }
        pipes.each do |pipe|
          @pipes.delete(pipe)
          @pipe_endpoints.delete(pipe)
        end
        pipes
      end
    end

    private def track_inproc_listener(name : String, endpoint : String) : Nil
      @state_mutex.synchronize do
        raise ClosedError.new("socket closed") if @closed
        @inproc_names << name
        @bound_endpoints << endpoint
      end
    end

    private def track_tcp_listener(listener : Transport::TCP::Listener) : Nil
      @state_mutex.synchronize do
        raise ClosedError.new("socket closed") if @closed
        @tcp_listeners << listener
        @bound_endpoints << listener.endpoint
      end
    end

    private def track_ipc_listener(listener : Transport::IPC::Listener) : Nil
      @state_mutex.synchronize do
        raise ClosedError.new("socket closed") if @closed
        @ipc_listeners << listener
        @bound_endpoints << listener.endpoint
      end
    end

    private def ensure_open! : Nil
      raise ClosedError.new("socket closed") if closed?
    end

    private def accept_inproc(listener : Transport::Inproc::Listener, endpoint : String) : Nil
      while pipe = listener.incoming.receive?
        break if closed?
        if register_pipe(pipe, endpoint)
          emit_monitor(MonitorEvent::Kind::Accepted, endpoint, pipe)
          spawn watch_pipe_close(pipe, endpoint)
        end
      end
    end

    private def accept_tcp(listener : Transport::TCP::Listener, endpoint : String) : Nil
      loop do
        tcp = listener.accept
        break unless tcp
        break if closed?
        begin
          pipe = Transport::TCP.adopt(
            tcp,
            local_socket_type: socket_type,
            local_identity: @options.identity,
            as_server: true,
            send_capacity: @options.send_capacity,
            recv_capacity: @options.recv_capacity,
            mechanism: @options.mechanism,
            max_message_size: @options.max_message_size,
            heartbeat_interval: @options.heartbeat_interval,
            heartbeat_ttl: @options.heartbeat_ttl,
            heartbeat_timeout: @options.heartbeat_timeout,
            sndbuf: @options.sndbuf,
            rcvbuf: @options.rcvbuf,
          )
          if register_pipe(pipe, endpoint)
            emit_monitor(MonitorEvent::Kind::Accepted, endpoint, pipe)
            spawn watch_pipe_close(pipe, endpoint)
          end
        rescue err : IO::Error | ProtocolError
          tcp.close rescue nil
          emit_monitor(MonitorEvent::Kind::HandshakeFailed, endpoint, error: err)
        end
      end
    end

    private def accept_ipc(listener : Transport::IPC::Listener, endpoint : String) : Nil
      loop do
        unix = listener.accept
        break unless unix
        break if closed?
        begin
          pipe = Transport::IPC.adopt(
            unix,
            local_socket_type: socket_type,
            local_identity: @options.identity,
            as_server: true,
            send_capacity: @options.send_capacity,
            recv_capacity: @options.recv_capacity,
            mechanism: @options.mechanism,
            max_message_size: @options.max_message_size,
            heartbeat_interval: @options.heartbeat_interval,
            heartbeat_ttl: @options.heartbeat_ttl,
            heartbeat_timeout: @options.heartbeat_timeout,
            sndbuf: @options.sndbuf,
            rcvbuf: @options.rcvbuf,
          )
          if register_pipe(pipe, endpoint)
            emit_monitor(MonitorEvent::Kind::Accepted, endpoint, pipe)
            spawn watch_pipe_close(pipe, endpoint)
          end
        rescue err : IO::Error | ProtocolError
          unix.close rescue nil
          emit_monitor(MonitorEvent::Kind::HandshakeFailed, endpoint, error: err)
        end
      end
    end

    private def watch_pipe_close(pipe : Pipe, endpoint : String) : Nil
      pipe.await_terminated
      return if closed?
      return unless unregister_pipe(pipe)
      emit_monitor(MonitorEvent::Kind::Disconnected, endpoint, pipe)
    end

    delegate send_hwm, recv_hwm, linger, identity,
      read_timeout, write_timeout, recv_timeout, send_timeout,
      reconnect_interval, heartbeat_interval, heartbeat_ttl, heartbeat_timeout,
      max_message_size, sndbuf, rcvbuf, on_mute, conflate, mechanism,
      router_mandatory?, to: @options

    {% for m in %w(send_hwm recv_hwm linger identity read_timeout write_timeout
                  recv_timeout send_timeout reconnect_interval heartbeat_interval
                  heartbeat_ttl heartbeat_timeout max_message_size sndbuf rcvbuf
                  on_mute conflate mechanism router_mandatory) %}
      def {{m.id}}=(val)
        @options.{{m.id}} = val
      end
    {% end %}
  end
end
