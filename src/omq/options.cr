module OMQ
  # Per-socket configuration. Numeric fields hold `Time::Span` for durations
  # and `Int32` for byte/message counts; `nil` means "disabled" or "OS default".
  class Options
    DEFAULT_HWM = 1000

    enum MuteStrategy
      Block
      DropNewest
      DropOldest
    end

    property send_hwm : Int32 = DEFAULT_HWM
    property recv_hwm : Int32 = DEFAULT_HWM

    # `nil` linger = wait forever (matching libzmq); `0.seconds` = immediate drop.
    property linger : Time::Span? = nil

    property identity : Bytes = Bytes.empty
    property? router_mandatory : Bool = false
    property conflate : Bool = false

    property read_timeout : Time::Span? = nil
    property write_timeout : Time::Span? = nil

    # Reconnect interval. A single `Time::Span` = fixed; a `Range` = exponential backoff (min..max).
    property reconnect_interval : Time::Span | Range(Time::Span, Time::Span) = 100.milliseconds

    property heartbeat_interval : Time::Span? = nil
    property heartbeat_ttl : Time::Span? = nil
    property heartbeat_timeout : Time::Span? = nil

    property max_message_size : Int64? = nil

    property sndbuf : Int32? = nil
    property rcvbuf : Int32? = nil

    property on_mute : MuteStrategy = MuteStrategy::Block

    property mechanism : ZMTP::Mechanism = ZMTP::Mechanism::Null.new

    def recv_timeout
      @read_timeout
    end

    def recv_timeout=(val : Time::Span?)
      @read_timeout = val
    end

    def send_timeout
      @write_timeout
    end

    def send_timeout=(val : Time::Span?)
      @write_timeout = val
    end

    def identity=(val : String)
      @identity = val.to_slice
    end

    def identity=(val : Bytes)
      @identity = val
    end
  end
end
