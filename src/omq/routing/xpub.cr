module OMQ
  module Routing
    # XPUB routing: same fan-out + on_mute semantics as `Pub`, plus a
    # peer-rx fan-in. Subscribe/cancel events sent by XSUB peers arrive
    # as ZMTP 3.0 legacy data frames whose first byte is 0x01 (subscribe)
    # or 0x00 (cancel). XPUB surfaces them verbatim on rx — no wire-level
    # interpretation, the app decides.
    class XPub < Strategy
      getter tx : Channel(Message)
      getter rx : Channel(Message)

      record PeerSlot, pipe : Pipe, drop : DropQueue(Message)?

      def initialize(capacity : Int32, @conflate : Bool = false, @on_mute : Options::MuteStrategy = Options::MuteStrategy::Block)
        @tx = Channel(Message).new(capacity)
        @rx = Channel(Message).new(capacity)
        @peer_slots = [] of PeerSlot
        @pipes_mutex = Mutex.new
        @closed = false
        @peer_hwm = capacity
      end

      def commit_capacity(send_hwm : Int32, recv_hwm : Int32, conflate : Bool, on_mute : Options::MuteStrategy) : Nil
        return if @closed
        @conflate = conflate
        @on_mute = on_mute
        @peer_hwm = send_hwm
        @tx = Channel(Message).new(send_hwm)
        @rx = Channel(Message).new(recv_hwm)
        spawn dispatcher
      end

      def attach(pipe : Pipe) : Nil
        return if @closed
        slot = build_slot(pipe)
        @pipes_mutex.synchronize { @peer_slots << slot }
        spawn recv_pump(pipe)
      end

      def close : Nil
        return if @closed
        @closed = true
        @tx.close
        @rx.close
        @pipes_mutex.synchronize do
          @peer_slots.each { |s| s.drop.try(&.close) }
        end
      end

      private def build_slot(pipe : Pipe) : PeerSlot
        case @on_mute
        when Options::MuteStrategy::Block
          PeerSlot.new(pipe: pipe, drop: nil)
        else
          drop = DropQueue(Message).new(@peer_hwm, @on_mute)
          spawn forward(drop, pipe)
          PeerSlot.new(pipe: pipe, drop: drop)
        end
      end

      private def forward(drop : DropQueue(Message), pipe : Pipe) : Nil
        while msg = drop.receive?
          begin
            pipe.tx.send(msg)
          rescue Channel::ClosedError
            break
          end
        end
      end

      private def recv_pump(pipe : Pipe) : Nil
        while msg = pipe.rx.receive?
          begin
            @rx.send(msg)
          rescue Channel::ClosedError
            break
          end
        end
      end

      private def dispatcher : Nil
        while msg = @tx.receive?
          if @conflate
            loop do
              select
              when newer = @tx.receive
                msg = newer
              else
                break
              end
            end
          end
          snapshot = @pipes_mutex.synchronize { @peer_slots.dup }
          snapshot.each do |slot|
            if drop = slot.drop
              drop.push(msg)
            else
              begin
                slot.pipe.tx.send(msg)
              rescue Channel::ClosedError
                @pipes_mutex.synchronize { @peer_slots.delete(slot) }
              end
            end
          end
        end
      end
    end
  end
end
