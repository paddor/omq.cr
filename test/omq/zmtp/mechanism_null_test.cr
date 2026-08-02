require "../../test_helper"

describe "OMQ::ZMTP::Mechanism::Null" do
  it "completes a handshake via a back-to-back IO pair" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      # Pipe 1: A writes, B reads.  IO.pipe → {read_end, write_end}
      b_reads, a_writes = IO.pipe
      # Pipe 2: B writes, A reads.
      a_reads, b_writes = IO.pipe

      a_io = OMQ::TestHelper::DuplexIO.new(read: a_reads, write: a_writes)
      b_io = OMQ::TestHelper::DuplexIO.new(read: b_reads, write: b_writes)

      a_done = Channel(Hash(String, Bytes)).new(1)

      spawn do
        a_done.send OMQ::ZMTP::Mechanism::Null.new.handshake(
          a_io, local_socket_type: "REQ", local_identity: "alice".to_slice, as_server: false
        )
      end

      b_props = OMQ::ZMTP::Mechanism::Null.new.handshake(
        b_io, local_socket_type: "REP", local_identity: "bob".to_slice, as_server: true
      )
      a_props = a_done.receive

      assert_equal "REP", String.new(a_props["Socket-Type"])
      assert_equal "bob", String.new(a_props["Identity"])
      assert_equal "REQ", String.new(b_props.not_nil!["Socket-Type"])
      assert_equal "alice", String.new(b_props.not_nil!["Identity"])
    end
  end
end
