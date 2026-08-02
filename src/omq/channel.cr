require "../omq"

module OMQ
  # CHANNEL (draft, ZeroMQ RFC 52): exclusive 1-to-1 bidirectional
  # socket. Single-frame messages. Only one peer at a time; a second
  # connection is dropped.
  #
  # Structurally identical to PAIR — the wire difference is the ZMTP
  # `Socket-Type` string (`CHANNEL` vs `PAIR`), so we reuse PAIR's
  # single-pipe plumbing and just override the advertised type.
  class CHANNEL < Socket
    include QueueReadable
    include QueueWritable

    @@default_action = :connect

    SOCKET_TYPE = "CHANNEL"

    @pipe : Pipe?
    @pipe_mutex : Mutex
    @pipe_ready : ::Channel(Bool)

    def initialize(endpoint : String? = nil, **opts)
      @pipe_mutex = Mutex.new
      @pipe_ready = ::Channel(Bool).new(1)
      super(endpoint, **opts)
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

    def receive : Message
      pipe = await_pipe(@options.read_timeout)
      channel_receive(pipe.rx)
    rescue ::Channel::ClosedError
      raise ClosedError.new("socket closed while receiving")
    end

    def receive? : Message?
      pipe = await_pipe?
      return nil unless pipe
      pipe.rx.receive?
    end

    protected def socket_type : String
      SOCKET_TYPE
    end

    protected def attach_pipe(pipe : Pipe) : Nil
      accepted = @pipe_mutex.synchronize do
        if current = @pipe
          @pipe = nil if current.closed?
        end

        if @pipe
          false
        else
          @pipe = pipe
          true
        end
      end

      unless accepted
        # CHANNEL is 1-to-1; a second peer is dropped.
        pipe.close
        return
      end

      signal_pipe_ready
    rescue ::Channel::ClosedError
      pipe.close
    end

    protected def on_close : Nil
      @pipe_ready.close unless @pipe_ready.closed?
    end

    private def send_frames(frames : Message) : self
      pipe = await_pipe(@options.write_timeout)
      channel_send(pipe.tx, frames)
      self
    rescue ::Channel::ClosedError
      raise ClosedError.new("socket closed while sending")
    end

    private def await_pipe(timeout span : Time::Span? = nil) : Pipe
      deadline = span ? Time.instant + span : nil
      loop do
        if pipe = active_pipe
          return pipe
        end

        if deadline
          remaining = deadline - Time.instant
          raise IO::TimeoutError.new("no peer connected after #{span}") unless remaining.positive?

          select
          when ready = @pipe_ready.receive?
            raise ClosedError.new("socket closed while waiting for peer") unless ready
          when timeout(remaining)
            raise IO::TimeoutError.new("no peer connected after #{span}")
          end
        else
          raise ClosedError.new("socket closed while waiting for peer") unless @pipe_ready.receive?
        end
      end
    end

    private def await_pipe? : Pipe?
      loop do
        if pipe = active_pipe
          return pipe
        end

        return nil unless @pipe_ready.receive?
      end
    end

    private def active_pipe : Pipe?
      @pipe_mutex.synchronize do
        if pipe = @pipe
          if pipe.closed?
            @pipe = nil
            nil
          else
            pipe
          end
        end
      end
    end

    private def signal_pipe_ready : Nil
      select
      when @pipe_ready.send(true)
      else
      end
    rescue ::Channel::ClosedError
    end
  end
end
