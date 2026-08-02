require "../test_helper"

describe "REP connection loss with pending reply" do
  it "discards a pending reply when the connection drops" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      rep = OMQ::REP.bind("tcp://127.0.0.1:0", linger: 0.seconds)
      port = rep.port.not_nil!

      req1 = OMQ::REQ.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds)
      req1.send("from-req1")
      assert_equal "from-req1", String.new(rep.receive[0])

      req1.close
      sleep 50.milliseconds

      rep.send("reply-to-req1")

      req2 = OMQ::REQ.connect("tcp://127.0.0.1:#{port}", linger: 0.seconds)
      req2.send("from-req2")
      assert_equal "from-req2", String.new(rep.receive[0])

      rep.send("reply-to-req2")
      assert_equal "reply-to-req2", String.new(req2.receive[0])

      req2.close
      rep.close
    end
  end
end
