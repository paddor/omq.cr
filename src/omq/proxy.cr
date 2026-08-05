module OMQ
  DEFAULT_PROXY_BURST_SIZE = 64

  enum ProxyExit
    Closed
    Terminated
  end

  enum ProxyState
    Active
    Paused
  end

  enum ProxyDirection
    FrontendToBackend
    BackendToFrontend

    def opposite : ProxyDirection
      self == FrontendToBackend ? BackendToFrontend : FrontendToBackend
    end
  end

  def self.proxy(frontend, backend, capture = nil, *, burst_size : Int32 = DEFAULT_PROXY_BURST_SIZE) : ProxyExit
    run_proxy(frontend, backend, capture, nil, burst_size)
  end

  def self.proxy_steerable(frontend, backend, control, capture = nil, *, burst_size : Int32 = DEFAULT_PROXY_BURST_SIZE) : ProxyExit
    run_proxy(frontend, backend, capture, control, burst_size)
  end

  private def self.run_proxy(frontend, backend, capture, control, burst_size : Int32) : ProxyExit
    burst_size = 1 if burst_size < 1
    state = ProxyState::Active
    preferred = ProxyDirection::FrontendToBackend
    fe_pending = nil.as(Message?)
    be_pending = nil.as(Message?)

    loop do
      case proxy_control_action(control)
      when "PAUSE"
        state = ProxyState::Paused
        proxy_control_reply(control)
      when "RESUME"
        state = ProxyState::Active
        proxy_control_reply(control)
      when "TERMINATE", "KILL"
        proxy_control_reply(control)
        return ProxyExit::Terminated
      when nil
      else
        proxy_control_reply(control)
      end

      progressed = false
      if state.active?
        progressed, fe_pending, be_pending = proxy_forward_direction(
          preferred, frontend, backend, capture, burst_size, fe_pending, be_pending
        )

        unless progressed
          progressed, fe_pending, be_pending = proxy_forward_direction(
            preferred.opposite, frontend, backend, capture, burst_size, fe_pending, be_pending
          )
        end

        preferred = preferred.opposite if progressed
      end

      return ProxyExit::Closed if frontend.closed? || backend.closed?
      return ProxyExit::Closed if control && control.closed?

      sleep 1.millisecond unless progressed
    end
  rescue ClosedError | Channel::ClosedError
    ProxyExit::Closed
  end

  private def self.proxy_forward_direction(
    direction : ProxyDirection,
    frontend,
    backend,
    capture,
    burst_size : Int32,
    fe_pending : Message?,
    be_pending : Message?,
  ) : {Bool, Message?, Message?}
    source = direction.frontend_to_backend? ? frontend : backend
    target = direction.frontend_to_backend? ? backend : frontend
    pending = direction.frontend_to_backend? ? fe_pending : be_pending
    progressed = false

    if pending
      if proxy_try_send(target, pending)
        proxy_capture(capture, pending)
        pending = nil
        progressed = true
      else
        return {false, direction.frontend_to_backend? ? pending : fe_pending, direction.frontend_to_backend? ? be_pending : pending}
      end
    end

    forwarded = 0
    while forwarded < burst_size
      msg = proxy_try_receive(source)
      break unless msg

      if proxy_try_send(target, msg)
        proxy_capture(capture, msg)
        progressed = true
        forwarded += 1
      else
        pending = msg
        progressed = true
        break
      end
    end

    {progressed, direction.frontend_to_backend? ? pending : fe_pending, direction.frontend_to_backend? ? be_pending : pending}
  end

  private def self.proxy_try_receive(socket) : Message?
    if socket.responds_to?(:try_receive)
      socket.try_receive
    else
      nil
    end
  end

  private def self.proxy_try_send(socket, msg : Message) : Bool
    if socket.responds_to?(:try_send)
      socket.try_send(msg)
    else
      false
    end
  end

  private def self.proxy_capture(capture, msg : Message) : Nil
    return unless capture
    proxy_try_send(capture, msg)
  rescue ClosedError
  end

  private def self.proxy_control_action(control) : String?
    return nil unless control
    msg = proxy_try_receive(control)
    return nil unless msg
    frame = msg.first? || Bytes.empty
    String.new(frame).upcase
  end

  private def self.proxy_control_reply(control) : Nil
    return unless control
    proxy_try_send(control, Message{Bytes.empty})
  rescue ClosedError
  end
end
