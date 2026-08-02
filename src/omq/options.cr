module OMQ
  # Per-socket configuration. Numeric fields hold `Time::Span` for durations
  # and `Int32` for byte/message counts. `nil` usually means disabled/OS
  # default; explicit nil HWM maps to 0, Ruby OMQ's unbounded spelling.
  class Options
    DEFAULT_HWM = 1000
    # Crystal's Channel is always bounded and preallocates for large
    # capacities. HWM=0 keeps the public "unbounded" spelling, but maps to
    # a generous internal cap until OMQ grows a dedicated unbounded queue.
    UNBOUNDED_HWM_CAPACITY = 65_536

    enum MuteStrategy
      Block
      DropNewest
      DropOldest
    end

    @send_hwm : Int32 = DEFAULT_HWM
    @recv_hwm : Int32 = DEFAULT_HWM

    # `nil` linger = wait forever (matching libzmq `-1`); `0.seconds` =
    # immediate close (drop in-flight). Default matches Ruby OMQ: drop.
    property linger : Time::Span? = 0.seconds

    @identity : Bytes = Bytes.empty

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

    def send_hwm : Int32
      @send_hwm
    end

    def send_hwm=(val : Int32)
      validate_hwm(val, "send_hwm")
      @send_hwm = val
    end

    def send_hwm=(val : Nil)
      @send_hwm = 0
    end

    def send_capacity : Int32
      self.class.channel_capacity(@send_hwm)
    end

    def recv_hwm : Int32
      @recv_hwm
    end

    def recv_hwm=(val : Int32)
      validate_hwm(val, "recv_hwm")
      @recv_hwm = val
    end

    def recv_hwm=(val : Nil)
      @recv_hwm = 0
    end

    def recv_capacity : Int32
      self.class.channel_capacity(@recv_hwm)
    end

    def self.channel_capacity(hwm : Int32) : Int32
      raise ArgumentError.new("hwm must be >= 0 (got #{hwm})") if hwm < 0
      hwm == 0 ? UNBOUNDED_HWM_CAPACITY : hwm
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

    def identity : Bytes
      @identity.dup
    end

    def identity=(val : String)
      @identity = val.to_slice
    end

    def identity=(val : Bytes)
      @identity = val.dup
    end

    # Symbol → MuteStrategy shim so `on_mute = :drop_newest` works, the
    # idiomatic Ruby-OMQ spelling.
    def on_mute=(val : Symbol)
      @on_mute = MuteStrategy.parse(val.to_s)
    end

    private def validate_hwm(val : Int32, name : String) : Nil
      raise ArgumentError.new("#{name} must be >= 0 (got #{val})") if val < 0
    end
  end
end
