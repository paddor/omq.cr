module OMQ
  module Routing

    # PEER routing: bidirectional multi-peer with auto-generated 4-byte
    # routing IDs. Mechanically identical to `Server` — on receive the ID
    # is prepended, on send it is consumed to pick the target pipe —
    # but used for RFC 51's peer-to-peer pattern (either side may bind
    # or connect).
    class Peer < Strategy
      getter rx : Channel(Message)
      getter tx : Channel(Message)


      def initialize(tx_capacity : Int32, rx_capacity : Int32)
        @tx          = Channel(Message).new(tx_capacity)
        @rx          = Channel(Message).new(rx_capacity)
        @pipes_by_id = {} of Bytes => Pipe
        @mutex       = Mutex.new
        @closed      = false
      end


      def commit_capacity(send_hwm : Int32, recv_hwm : Int32) : Nil
        return if @closed
        @tx = Channel(Message).new(send_hwm)
        @rx = Channel(Message).new(recv_hwm)
        spawn dispatcher
      end


      def attach(pipe : Pipe) : Nil
        return if @closed
        id = Random::Secure.random_bytes(4)
        @mutex.synchronize { @pipes_by_id[id] = pipe }
        spawn recv_pump(pipe, id)
      end


      def close : Nil
        return if @closed
        @closed = true
        @tx.close
        @rx.close
      end


      # Snapshot of current peer routing IDs. Useful for tests and for
      # initiating addressed sends after a peer has connected but before
      # it has sent us anything.
      def peer_routing_ids : Array(Bytes)
        @mutex.synchronize { @pipes_by_id.keys }
      end


      private def recv_pump(pipe : Pipe, id : Bytes) : Nil
        while msg = pipe.rx.receive?
          prepended = Message.new(msg.size + 1)
          prepended << id
          msg.each { |p| prepended << p }
          begin
            @rx.send(prepended)
          rescue Channel::ClosedError
            break
          end
        end
      ensure
        @mutex.synchronize { @pipes_by_id.delete(id) }
      end


      private def dispatcher : Nil
        while msg = @tx.receive?
          next if msg.empty?
          id = msg[0]
          pipe = @mutex.synchronize { @pipes_by_id[id]? }
          next if pipe.nil?
          body = msg.size > 1 ? msg[1..] : Message.new
          begin
            pipe.tx.send(body)
          rescue Channel::ClosedError
            @mutex.synchronize { @pipes_by_id.delete(id) }
          end
        end
      end
    end
  end
end
