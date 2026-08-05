require "../test_helper"

describe "PLAIN mechanism" do
  it "REQ/REP round-trips over TCP" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      rep = OMQ::REP.new
      rep.mechanism = OMQ::ZMTP::Mechanism::Plain.server({"alice" => "secret"})
      rep.bind("tcp://127.0.0.1:0")
      port = rep.port.not_nil!

      req = OMQ::REQ.new
      req.mechanism = OMQ::ZMTP::Mechanism::Plain.client("alice", "secret")
      req.connect("tcp://127.0.0.1:#{port}")

      req.send("hello")
      assert_equal "hello", String.new(rep.receive[0])
      rep.send("world")
      assert_equal "world", String.new(req.receive[0])

      req.close
      rep.close
    end
  end

  it "runs the server authenticator" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      seen = Channel({String, String}).new(1)
      pull = OMQ::PULL.new
      pull.mechanism = OMQ::ZMTP::Mechanism::Plain.server do |username, password|
        select
        when seen.send({username, password})
        else
        end
        username == "alice" && password == "secret"
      end
      pull.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!

      push = OMQ::PUSH.new
      push.mechanism = OMQ::ZMTP::Mechanism::Plain.client("alice", "secret")
      push.connect("tcp://127.0.0.1:#{port}")

      push.send("plain")
      assert_equal "plain", String.new(pull.receive[0])
      assert_equal({"alice", "secret"}, seen.receive)

      push.close
      pull.close
    end
  end

  it "rejects wrong credentials" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.new(read_timeout: 300.milliseconds)
      events = pull.monitor
      pull.mechanism = OMQ::ZMTP::Mechanism::Plain.server({"alice" => "secret"})
      pull.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!

      push = OMQ::PUSH.new
      push.mechanism = OMQ::ZMTP::Mechanism::Plain.client("alice", "wrong")
      push.connect("tcp://127.0.0.1:#{port}")
      push.send("ghost")

      failed = OMQ::TestHelper.wait_monitor_event(events, OMQ::MonitorEvent::Kind::HandshakeFailed)
      assert_match(/PLAIN credentials rejected/, failed.error.not_nil!.message.not_nil!)
      assert_raises(IO::TimeoutError) { pull.receive }

      push.close
      pull.close
    end
  end

  it "rejects overlong client credentials" do
    assert_raises(OMQ::HandshakeFailed) do
      OMQ::ZMTP::Mechanism::Plain.client("x" * 256, "ok")
    end
  end
end
