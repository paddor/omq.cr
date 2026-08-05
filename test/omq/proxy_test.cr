require "../test_helper"

describe "OMQ.proxy" do
  private def start_proxy(frontend, backend, control, capture = nil, burst_size = OMQ::DEFAULT_PROXY_BURST_SIZE)
    done = Channel(OMQ::ProxyExit | Exception).new(1)
    spawn do
      begin
        done.send(OMQ.proxy_steerable(frontend, backend, control, capture, burst_size: burst_size))
      rescue ex
        done.send(ex)
      end
    end
    done
  end

  private def send_control(controller : OMQ::REQ, command : String) : Nil
    controller.send(command)
    controller.receive
  end

  private def wait_proxy(done : Channel(OMQ::ProxyExit | Exception)) : OMQ::ProxyExit
    result = done.receive
    raise result if result.is_a?(Exception)
    result
  end

  it "pauses, resumes, and terminates a steerable PULL to PUSH proxy" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      frontend = OMQ::PULL.bind("inproc://proxy-steer-fe")
      backend = OMQ::PUSH.bind("inproc://proxy-steer-be")
      control = OMQ::REP.bind("inproc://proxy-steer-control")
      sender = OMQ::PUSH.connect("inproc://proxy-steer-fe")
      receiver = OMQ::PULL.connect("inproc://proxy-steer-be")
      controller = OMQ::REQ.connect("inproc://proxy-steer-control")

      done = start_proxy(frontend, backend, control)

      sender.send("hello")
      assert_equal "hello", String.new(receiver.receive[0])

      send_control(controller, "PAUSE")
      sender.send("paused")
      sleep 50.milliseconds
      assert_nil receiver.try_receive

      send_control(controller, "RESUME")
      assert_equal "paused", String.new(receiver.receive[0])

      send_control(controller, "TERMINATE")
      assert_equal OMQ::ProxyExit::Terminated, wait_proxy(done)

      controller.close
      receiver.close
      sender.close
      control.close
      backend.close
      frontend.close
    end
  end

  it "sends best-effort capture copies" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      frontend = OMQ::PULL.bind("inproc://proxy-capture-fe")
      backend = OMQ::PUSH.bind("inproc://proxy-capture-be")
      capture = OMQ::PUSH.bind("inproc://proxy-capture-copy")
      control = OMQ::REP.bind("inproc://proxy-capture-control")
      sender = OMQ::PUSH.connect("inproc://proxy-capture-fe")
      receiver = OMQ::PULL.connect("inproc://proxy-capture-be")
      captured = OMQ::PULL.connect("inproc://proxy-capture-copy")
      controller = OMQ::REQ.connect("inproc://proxy-capture-control")

      done = start_proxy(frontend, backend, control, capture)

      sender.send("trace")
      assert_equal "trace", String.new(receiver.receive[0])
      assert_equal "trace", String.new(captured.receive[0])

      send_control(controller, "KILL")
      assert_equal OMQ::ProxyExit::Terminated, wait_proxy(done)

      controller.close
      captured.close
      receiver.close
      sender.close
      control.close
      capture.close
      backend.close
      frontend.close
    end
  end

  it "bounds hot-side bursts so the reverse direction can run" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      frontend = OMQ::PAIR.bind("inproc://proxy-fair-fe")
      backend = OMQ::PAIR.bind("inproc://proxy-fair-be")
      control = OMQ::REP.bind("inproc://proxy-fair-control")
      client = OMQ::PAIR.connect("inproc://proxy-fair-fe")
      server = OMQ::PAIR.connect("inproc://proxy-fair-be")
      controller = OMQ::REQ.connect("inproc://proxy-fair-control")

      done = start_proxy(frontend, backend, control, nil, 4)

      32.times { |i| client.send("load-#{i}") }
      server.send("probe")

      probe = nil.as(OMQ::Message?)
      OMQ::TestHelper.wait_until { !!(probe = client.try_receive) }
      assert_equal "probe", String.new(probe.not_nil![0])

      send_control(controller, "TERMINATE")
      assert_equal OMQ::ProxyExit::Terminated, wait_proxy(done)

      controller.close
      server.close
      client.close
      control.close
      backend.close
      frontend.close
    end
  end
end
