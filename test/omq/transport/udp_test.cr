require "../../test_helper"

describe "OMQ::Transport::UDP" do
  it "round-trips datagrams" do
    bytes = OMQ::Transport::UDP.encode_datagram("weather".to_slice, "sunny".to_slice)
    msg = OMQ::Transport::UDP.decode_datagram(bytes).not_nil!

    assert_equal "weather", String.new(msg[0])
    assert_equal "sunny", String.new(msg[1])
  end

  it "drops malformed datagrams" do
    assert_nil OMQ::Transport::UDP.decode_datagram(Bytes.empty)
    assert_nil OMQ::Transport::UDP.decode_datagram(Bytes[0x00, 0x00])
    assert_nil OMQ::Transport::UDP.decode_datagram(Bytes[0x01, 10, 1, 2])
  end

  it "rejects oversized groups" do
    assert_raises(OMQ::ProtocolError) do
      OMQ::Transport::UDP.encode_datagram(Bytes.new(256, 0x67_u8), "x".to_slice)
    end
  end
end
