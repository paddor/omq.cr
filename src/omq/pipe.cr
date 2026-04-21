module OMQ
  # A pipe is one end of a bidirectional connection between two sockets.
  # Owners read from `rx` and write to `tx`. The transport decides how
  # those channels are backed: inproc pairs them directly with channels
  # on the other peer; TCP/IPC spawn pump fibers that bridge a channel
  # pair to an underlying `ZMTP::Connection`.
  class Pipe
    getter tx : Channel(Message)
    getter rx : Channel(Message)

    def initialize(@tx : Channel(Message), @rx : Channel(Message))
    end

    # Two pipes sharing a crossed channel pair (for inproc).
    def self.pair(capacity : Int32) : {Pipe, Pipe}
      a_to_b = Channel(Message).new(capacity)
      b_to_a = Channel(Message).new(capacity)
      {Pipe.new(tx: a_to_b, rx: b_to_a), Pipe.new(tx: b_to_a, rx: a_to_b)}
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
