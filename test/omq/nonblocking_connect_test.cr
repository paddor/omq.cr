require "../test_helper"

private def unused_tcp_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  server.close
  port
end

describe "Non-blocking TCP connect" do
  it "connect returns immediately when endpoints are unreachable" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      req = OMQ::REQ.new(linger: 0.seconds, reconnect_interval: 1.second)
      ports = Array.new(3) { unused_tcp_port }

      elapsed = Time.measure do
        ports.each { |port| req.connect("tcp://127.0.0.1:#{port}") }
      end

      assert elapsed < 500.milliseconds, "connect should not block; took #{elapsed}"

      req.close
    end
  end

  it "connects in the background when the server appears later" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      port = unused_tcp_port
      req = OMQ::REQ.connect(
        "tcp://127.0.0.1:#{port}",
        linger: 0.seconds,
        reconnect_interval: 20.milliseconds,
      )

      sleep 50.milliseconds
      rep = OMQ::REP.bind("tcp://127.0.0.1:#{port}", linger: 0.seconds)
      OMQ::TestHelper.wait_until { req.peer_count > 0 && rep.peer_count > 0 }

      req.send("async connect")

      assert_equal "async connect", String.new(rep.receive[0])

      req.close
      rep.close
    end
  end
end
