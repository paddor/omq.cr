require "../test_helper"

describe "sndbuf/rcvbuf" do
  it "applies SO_SNDBUF and SO_RCVBUF to TCP connect-side sockets" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!

      push = OMQ::PUSH.new
      push.sndbuf = 64 * 1024
      push.rcvbuf = 64 * 1024
      push.connect("tcp://127.0.0.1:#{port}")

      push.send("hello")
      assert_equal "hello", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end

  it "applies buffer sizes to accepted TCP sockets" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.new
      pull.sndbuf = 64 * 1024
      pull.rcvbuf = 64 * 1024
      pull.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!

      push = OMQ::PUSH.connect("tcp://127.0.0.1:#{port}")

      push.send("hello")
      assert_equal "hello", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end
end
