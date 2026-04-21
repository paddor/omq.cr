module OMQ
  module Routing
    # PUB routing: fan-out to every connected peer.
    #
    # v0.1 does not yet negotiate SUBSCRIBE/CANCEL over the wire; every
    # message is fanned out and filtering happens on the SUB side. This
    # is correct for OMQ-to-OMQ traffic on any transport, but wastes
    # bandwidth on TCP and does not interoperate with libzmq PUB sockets
    # (which require SUBSCRIBE before they send). Wire-level subscribe
    # support is tracked separately.
    class Pub < Strategy
      getter tx : Channel(Message)

      # When on_mute is a drop strategy, each peer gets its own DropQueue
      # and a forwarder fiber draining into pipe.tx. In Block mode we
      # fan out to pipe.tx directly — the dispatcher blocks on any slow
      # peer, same as libzmq ZMQ_XPUB_NODROP.
      record PeerSlot, pipe : Pipe, drop : DropQueue(Message)?

      def initialize(capacity : Int32, @conflate : Bool = false, @on_mute : Options::MuteStrategy = Options::MuteStrategy::Block)
        @tx = Channel(Message).new(capacity)
        @peer_slots = [] of PeerSlot
        @pipes_mutex = Mutex.new
        @closed = false
        @peer_hwm = capacity
      end

      # Called once on first bind/connect (via Socket's commit gate).
      # Installs the finalized @tx capacity and starts the dispatcher.
      def commit_capacity(send_hwm : Int32, recv_hwm : Int32, conflate : Bool, on_mute : Options::MuteStrategy) : Nil
        return if @closed
        @conflate = conflate
        @on_mute = on_mute
        @peer_hwm = send_hwm
        @tx = Channel(Message).new(send_hwm)
        spawn dispatcher
      end

      def attach(pipe : Pipe) : Nil
        return if @closed
        slot = build_slot(pipe)
        @pipes_mutex.synchronize { @peer_slots << slot }
      end

      def close : Nil
        return if @closed
        @closed = true
        @tx.close
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

      # Drains a per-peer DropQueue into the pipe's tx. A blocking send
      # to pipe.tx is fine here — the DropQueue upstream has already
      # absorbed any burst, and pipe.tx's own HWM acts as a second,
      # peer-level backstop.
      private def forward(drop : DropQueue(Message), pipe : Pipe) : Nil
        while msg = drop.receive?
          begin
            pipe.tx.send(msg)
          rescue Channel::ClosedError
            break
          end
        end
      end

      private def dispatcher : Nil
        while msg = @tx.receive?
          if @conflate
            # Conflate: drain any further queued messages non-blockingly
            # and keep only the most recent one. Stale updates get dropped
            # so slow subscribers see only the latest state, not backlog.
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
