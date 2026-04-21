module OMQ
  # A pipe is one end of a bidirectional connection between two sockets.
  # Owners read from `rx` and write to `tx`. The transport decides how
  # those channels are backed: inproc pairs them directly with channels
  # on the other peer; TCP/IPC spawn pump fibers that bridge a channel
  # pair to an underlying `ZMTP::Connection`.
  class Pipe
    getter tx : Channel(Message)
    getter rx : Channel(Message)
    # Closed by the TCP/IPC write pump when it has finished flushing
    # everything in `tx` to the wire (or the wire has gone away). Inproc
    # pipes have no pump, so the channel is pre-closed at construction —
    # the peer already holds the messages as soon as `#send` returns.
    getter send_done : Channel(Nil)
    # Identity the *remote* peer advertised (via ZMTP handshake for TCP,
    # via the connector's options.identity for inproc). Empty means the
    # peer didn't advertise one; ROUTER will substitute a random ID.
    property peer_identity : Bytes = Bytes.empty

    def initialize(@tx : Channel(Message), @rx : Channel(Message), @send_done : Channel(Nil) = Pipe.pre_closed_channel)
    end

    protected def self.pre_closed_channel : Channel(Nil)
      ch = Channel(Nil).new
      ch.close
      ch
    end

    # Two pipes sharing a crossed channel pair (for inproc).
    def self.pair(capacity : Int32) : {Pipe, Pipe}
      a_to_b = Channel(Message).new(capacity)
      b_to_a = Channel(Message).new(capacity)
      {Pipe.new(tx: a_to_b, rx: b_to_a), Pipe.new(tx: b_to_a, rx: a_to_b)}
    end

    # Stop accepting new outgoing messages; let the write pump flush
    # what's already buffered and then close itself.
    def close_send : Nil
      @tx.close unless @tx.closed?
    end

    # Block until the write pump has drained `tx` (or `span` elapses).
    # Returns `true` on drain, `false` on timeout. `nil` = wait forever.
    def await_drained(span : Time::Span?) : Bool
      case span
      when nil
        @send_done.receive?
        true
      else
        select
        when @send_done.receive?
          true
        when timeout(span)
          false
        end
      end
    end

    def close : Nil
      @tx.close
      @rx.close
    end

    def closed? : Bool
      @tx.closed? || @rx.closed?
    end
  end
end
