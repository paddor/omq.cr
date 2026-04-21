module OMQ
  # Socket base class. Concrete types (`PAIR`, `PUSH`, `PULL`, ...) subclass
  # this and plug in a routing strategy.
  #
  # Endpoint prefix convention:
  # - `@endpoint` → bind
  # - `>endpoint` → connect
  # - plain      → use the subclass default (`DEFAULT_ACTION`)
  abstract class Socket
    # Set by subclasses: `:bind` or `:connect`.
    class_property default_action : Symbol = :connect

    getter options : Options
    getter? closed : Bool = false

    def initialize(endpoint : String? = nil)
      @options = Options.new
      attach(endpoint) if endpoint
    end

    def self.bind(endpoint : String, **opts) : self
      new("@#{endpoint}", **opts)
    end

    def self.connect(endpoint : String, **opts) : self
      new(">#{endpoint}", **opts)
    end

    # Accept a prefix-tagged endpoint. `@x` → bind, `>x` → connect,
    # plain → subclass default.
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

    abstract def bind(endpoint : String) : self
    abstract def connect(endpoint : String) : self
    abstract def close : Nil

    # Parse `scheme://rest`.
    protected def parse_endpoint(endpoint : String) : {String, String}
      idx = endpoint.index("://") || raise InvalidEndpoint.new("missing scheme: #{endpoint}")
      {endpoint[0...idx], endpoint[idx + 3..]}
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
