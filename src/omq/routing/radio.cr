module OMQ
  module Routing
    # RADIO routing: broadcast `[group, body]` to every attached DISH
    # peer. JOIN/LEAVE commands are observed for readiness parity with
    # Ruby OMQ, while group filtering still happens on the DISH side.
    class Radio < Strategy
      getter tx : ::Channel(Message)
      getter subscriber_joined : ::Channel(Pipe)

      def initialize(capacity : Int32)
        @tx = ::Channel(Message).new(capacity)
        @subscriber_joined = ::Channel(Pipe).new(128)
        @pipes = [] of Pipe
        @pipes_mutex = Mutex.new
        @closed = Atomic(Bool).new(false)
      end

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if closed?
        @tx = ::Channel(Message).new(send_hwm)
        spawn dispatcher
      end

      def attach(pipe : Pipe) : Nil
        return if closed?
        @pipes_mutex.synchronize { @pipes << pipe }
        spawn command_listener(pipe)
      end

      def close : Nil
        return unless close_once
        @tx.close
        @subscriber_joined.close
      end

      private def command_listener(pipe : Pipe) : Nil
        commands = pipe.commands_rx
        return unless commands
        while event = commands.receive?
          next unless event.name == "JOIN"
          notify_subscriber_joined(pipe)
        end
      end

      private def notify_subscriber_joined(pipe : Pipe) : Nil
        select
        when @subscriber_joined.send(pipe)
        else
        end
      rescue ::Channel::ClosedError
      end

      private def dispatcher : Nil
        while msg = @tx.receive?
          snapshot = @pipes_mutex.synchronize { @pipes.dup }
          snapshot.each do |pipe|
            begin
              pipe.tx.send(msg)
            rescue ::Channel::ClosedError
              @pipes_mutex.synchronize { @pipes.delete(pipe) }
            end
          end
        end
      end
    end
  end
end
