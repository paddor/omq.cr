module OMQ
  module Transport
    # In-process transport. Two matched `Channel(Message)`s per connection:
    # one direction each. No bytes, no framing — `Message` = `Array(Bytes)`
    # flows directly between fibers.
    module Inproc
      # One half of a bidirectional inproc connection. The owning socket
      # reads from `rx` and writes to `tx`. The peer owns the mirror.
      class Pipe
        getter tx : Channel(Message)
        getter rx : Channel(Message)

        def initialize(@tx : Channel(Message), @rx : Channel(Message))
        end

        # Create a matched pair of pipes sharing two underlying channels.
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

      # Process-global registry of bound inproc endpoints.
      class Listener
        getter name : String
        getter incoming : Channel(Pipe)

        def initialize(@name : String)
          @incoming = Channel(Pipe).new(64)
        end

        def close : Nil
          @incoming.close
        end
      end

      @@listeners = {} of String => Listener
      @@mutex = Mutex.new

      # Remove all listeners. Tests call this before each scenario.
      def self.reset! : Nil
        @@mutex.synchronize do
          @@listeners.each_value(&.close)
          @@listeners.clear
        end
      end

      def self.bind(name : String) : Listener
        @@mutex.synchronize do
          if @@listeners.has_key?(name)
            raise InvalidEndpoint.new("inproc://#{name} already bound")
          end
          listener = Listener.new(name)
          @@listeners[name] = listener
          listener
        end
      end

      def self.unbind(name : String) : Nil
        @@mutex.synchronize do
          if listener = @@listeners.delete(name)
            listener.close
          end
        end
      end

      # Look up a listener. Returns nil if not bound yet.
      def self.lookup(name : String) : Listener?
        @@mutex.synchronize { @@listeners[name]? }
      end

      # Connect to a bound listener. Creates a matched pipe pair; one end
      # goes to the listener's incoming channel, the other is returned.
      # Raises `InvalidEndpoint` if the listener doesn't exist.
      def self.connect(name : String, capacity : Int32) : Pipe
        listener = lookup(name) || raise InvalidEndpoint.new(
          "inproc://#{name} not bound (no listener)"
        )
        local, remote = Pipe.pair(capacity)
        listener.incoming.send(remote)
        local
      end
    end
  end
end
