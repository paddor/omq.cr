module OMQ
  module Routing
    # RADIO routing: broadcast `[group, body]` to peers that joined the
    # message group.
    class Radio < Strategy
      getter tx : ::Channel(Message)
      getter subscriber_joined : ::Channel(Pipe)

      def initialize(capacity : Int32)
        @tx = ::Channel(Message).new(capacity)
        @subscriber_joined = ::Channel(Pipe).new(128)
        @pipes = [] of Pipe
        @broadcast_pipes = [] of Pipe
        @pipes_mutex = Mutex.new
        @groups = {} of Pipe => Set(String)
        @groups_mutex = Mutex.new
        @closed = Atomic(Bool).new(false)
      end

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if closed?
        @tx = ::Channel(Message).new(send_hwm)
        spawn dispatcher
      end

      def attach(pipe : Pipe) : Nil
        return if closed?
        @pipes_mutex.synchronize do
          @pipes << pipe
          if pipe.radio_broadcast_all?
            @broadcast_pipes << pipe
          else
            @groups_mutex.synchronize { @groups[pipe] = Set(String).new }
          end
        end
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
          case event.name
          when "JOIN"
            join(pipe, String.new(event.body))
          when "LEAVE"
            leave(pipe, String.new(event.body))
          end
        end
      ensure
        remove_pipe(pipe)
      end

      private def join(pipe : Pipe, group : String) : Nil
        @groups_mutex.synchronize do
          groups = @groups[pipe]? || return
          return unless groups.add?(group)
        end
        notify_subscriber_joined(pipe)
      end

      private def leave(pipe : Pipe, group : String) : Nil
        @groups_mutex.synchronize do
          groups = @groups[pipe]? || return
          groups.delete(group)
        end
      end

      private def joined?(pipe : Pipe, group : String) : Bool
        return true if @pipes_mutex.synchronize { @broadcast_pipes.includes?(pipe) }
        @groups_mutex.synchronize { @groups[pipe]?.try(&.includes?(group)) || false }
      end

      private def remove_pipe(pipe : Pipe) : Nil
        @pipes_mutex.synchronize do
          @pipes.delete(pipe)
          @broadcast_pipes.delete(pipe)
        end
        @groups_mutex.synchronize { @groups.delete(pipe) }
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
          group = String.new(msg.first? || Bytes.empty)
          snapshot = @pipes_mutex.synchronize { @pipes.dup }
          snapshot.each do |pipe|
            next unless joined?(pipe, group)
            begin
              pipe.tx.send(msg)
            rescue ::Channel::ClosedError
              remove_pipe(pipe)
            end
          end
        end
      end
    end
  end
end
