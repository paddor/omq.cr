module OMQ
  module Routing

    # DISH routing: fair-queue receive from RADIO peers, filtering by
    # joined group. The group is carried as the first frame of every
    # RADIO message; only messages whose group matches a joined group
    # reach the app.
    #
    # `#join` / `#leave` also emit ZMTP `JOIN` / `LEAVE` commands to
    # every attached peer. v0.1 RADIO ignores those (it broadcasts
    # every message and leaves filtering to DISH), but sending them
    # keeps interop with libzmq RADIOs that do filter upstream.
    class Dish < Strategy
      getter rx : ::Channel(Message)


      def initialize(capacity : Int32)
        @rx             = ::Channel(Message).new(capacity)
        @groups         = Set(String).new
        @groups_mutex   = Mutex.new
        @pipes          = [] of Pipe
        @pipes_mutex    = Mutex.new
        @closed         = false
      end


      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if @closed
        @rx = ::Channel(Message).new(recv_hwm)
      end


      def join(group : String) : Nil
        @groups_mutex.synchronize do
          return unless @groups.add?(group)
        end
        broadcast_group_command(0x01_u8, group)
      end


      def leave(group : String) : Nil
        @groups_mutex.synchronize do
          return unless @groups.delete(group)
        end
        broadcast_group_command(0x00_u8, group)
      end


      def attach(pipe : Pipe) : Nil
        return if @closed
        @pipes_mutex.synchronize { @pipes << pipe }

        # Replay current joins so a new peer knows our groups.
        snapshot = @groups_mutex.synchronize { @groups.to_a }
        snapshot.each { |g| send_group_command(pipe, 0x01_u8, g) }

        spawn drain(pipe)
      end


      def close : Nil
        return if @closed
        @closed = true
        @rx.close
      end


      private def broadcast_group_command(marker : UInt8, group : String) : Nil
        snapshot = @pipes_mutex.synchronize { @pipes.dup }
        snapshot.each { |p| send_group_command(p, marker, group) }
      end


      private def send_group_command(pipe : Pipe, marker : UInt8, group : String) : Nil
        cmd = marker == 0x01_u8 ? ZMTP::Command.join(group) : ZMTP::Command.leave(group)
        pipe.send_command(cmd)
      end


      private def drain(pipe : Pipe) : Nil
        while msg = pipe.rx.receive?
          next unless matches?(msg)
          begin
            @rx.send(msg)
          rescue ::Channel::ClosedError
            break
          end
        end
      end


      private def matches?(msg : Message) : Bool
        return false if msg.empty?
        group = String.new(msg[0])
        @groups_mutex.synchronize { @groups.includes?(group) }
      end
    end
  end
end
