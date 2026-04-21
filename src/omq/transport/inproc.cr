module OMQ
  module Transport
    # In-process transport: two matched `Channel(Message)`s per connection,
    # one direction each. No serialization, no framing — `Message` flows
    # directly between fibers.
    module Inproc
      extend self

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

      def reset! : Nil
        @@mutex.synchronize do
          @@listeners.each_value(&.close)
          @@listeners.clear
        end
      end

      def bind(name : String) : Listener
        @@mutex.synchronize do
          if @@listeners.has_key?(name)
            raise InvalidEndpoint.new("inproc://#{name} already bound")
          end
          listener = Listener.new(name)
          @@listeners[name] = listener
          listener
        end
      end

      def unbind(name : String) : Nil
        @@mutex.synchronize do
          if listener = @@listeners.delete(name)
            listener.close
          end
        end
      end

      def lookup(name : String) : Listener?
        @@mutex.synchronize { @@listeners[name]? }
      end

      def connect(name : String, capacity : Int32, local_identity : Bytes = Bytes.empty) : Pipe
        listener = lookup(name) || raise InvalidEndpoint.new(
          "inproc://#{name} not bound (no listener)"
        )
        local, remote = Pipe.pair(capacity)
        remote.peer_identity = local_identity
        listener.incoming.send(remote)
        local
      end
    end
  end
end
