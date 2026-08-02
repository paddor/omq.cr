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
      @@pending = {} of String => Array(Pipe)
      @@mutex = Mutex.new

      def reset! : Nil
        @@mutex.synchronize do
          @@listeners.each_value(&.close)
          @@pending.each_value { |pipes| pipes.each(&.close) }
          @@listeners.clear
          @@pending.clear
        end
      end

      def bind(name : String) : Listener
        listener, pending = @@mutex.synchronize do
          if @@listeners.has_key?(name)
            raise InvalidEndpoint.new("inproc://#{name} already bound")
          end
          listener = Listener.new(name)
          @@listeners[name] = listener
          {listener, @@pending.delete(name)}
        end

        spawn deliver_pending(listener, pending) if pending
        listener
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
        local, remote = Pipe.pair(capacity)
        remote.peer_identity = local_identity
        listener = @@mutex.synchronize do
          if bound = @@listeners[name]?
            bound
          else
            (@@pending[name] ||= [] of Pipe) << remote
            nil
          end
        end
        listener.try do |bound|
          begin
            bound.incoming.send(remote)
          rescue Channel::ClosedError
            remote.close
          end
        end
        local
      end

      private def deliver_pending(listener : Listener, pipes : Array(Pipe)) : Nil
        pipes.each do |pipe|
          next if pipe.closed?
          begin
            listener.incoming.send(pipe)
          rescue Channel::ClosedError
            pipe.close
          end
        end
      end
    end
  end
end
