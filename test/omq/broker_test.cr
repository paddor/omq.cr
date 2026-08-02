require "../test_helper"

private def with_broker(workers : Int32 = 1, client_id : String = "client-1", &block : OMQ::REQ ->)
  frontend = OMQ::ROUTER.bind("inproc://broker-fe-#{client_id}")
  backend = OMQ::DEALER.bind("inproc://broker-be-#{client_id}")
  reps = [] of OMQ::REP

  spawn do
    while msg = frontend.receive?
      backend.send(msg)
    end
  rescue OMQ::ClosedError | Channel::ClosedError
  end

  spawn do
    while msg = backend.receive?
      frontend.send(msg)
    end
  rescue OMQ::ClosedError | Channel::ClosedError
  end

  workers.times do
    rep = OMQ::REP.connect("inproc://broker-be-#{client_id}")
    reps << rep
    spawn do
      while msg = rep.receive?
        rep.send(msg)
      end
    rescue OMQ::ClosedError | Channel::ClosedError
    end
  end

  req = OMQ::REQ.connect("inproc://broker-fe-#{client_id}", identity: client_id)
  block.call(req)
ensure
  req.try(&.close)
  reps.try(&.each(&.close))
  frontend.try(&.close)
  backend.try(&.close)
end

describe "ROUTER/DEALER broker over inproc" do
  it "routes a request through a ROUTER/DEALER broker to a REP worker" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      with_broker do |req|
        req.send("hello")

        assert_equal "hello", String.new(req.receive[0])
      end
    end
  end

  it "handles multiple round trips through the broker" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      with_broker(client_id: "client-2") do |req|
        10.times do |i|
          req.send("msg-#{i}")

          assert_equal "msg-#{i}", String.new(req.receive[0])
        end
      end
    end
  end

  it "routes to multiple workers" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      with_broker(workers: 4, client_id: "client-3") do |req|
        20.times do |i|
          req.send("msg-#{i}")

          assert_equal "msg-#{i}", String.new(req.receive[0])
        end
      end
    end
  end
end
