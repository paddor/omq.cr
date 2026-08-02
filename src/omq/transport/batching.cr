module OMQ::Transport
  WRITE_BATCH_MESSAGES = 64
  WRITE_BATCH_BYTES    = 64 * 1024

  def self.drain_data_batch(first : Message, tx : Channel(Message), batch : Array(Message)) : Nil
    batch.clear
    batch << first
    bytes = message_wire_size(first)

    while batch.size < WRITE_BATCH_MESSAGES && bytes < WRITE_BATCH_BYTES
      begin
        select
        when msg = tx.receive
          batch << msg
          bytes += message_wire_size(msg)
        else
          break
        end
      rescue Channel::ClosedError
        break
      end
    end
  end

  def self.message_wire_size(msg : Message) : Int32
    msg.reduce(0) do |sum, frame|
      sum + frame.size + (frame.size > 255 ? 9 : 2)
    end
  end
end
