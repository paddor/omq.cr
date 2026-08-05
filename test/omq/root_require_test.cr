require "../test_helper"

describe "require omq" do
  it "exports draft socket constants" do
    assert_equal "CLIENT", OMQ::CLIENT::SOCKET_TYPE
    assert_equal "SERVER", OMQ::SERVER::SOCKET_TYPE
    assert_equal "RADIO", OMQ::RADIO::SOCKET_TYPE
    assert_equal "DISH", OMQ::DISH::SOCKET_TYPE
    assert_equal "SCATTER", OMQ::SCATTER::SOCKET_TYPE
    assert_equal "GATHER", OMQ::GATHER::SOCKET_TYPE
    assert_equal "PEER", OMQ::PEER::SOCKET_TYPE
    assert_equal "CHANNEL", OMQ::CHANNEL::SOCKET_TYPE
  end
end
