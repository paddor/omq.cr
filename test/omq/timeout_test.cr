require "../test_helper"

describe "send_timeout" do
  it "raises IO::TimeoutError when send blocks longer than send_timeout" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      push = OMQ::PUSH.new
      push.send_hwm = 1
      push.write_timeout = 20.milliseconds
      push.linger = 0.seconds
      push.bind("ipc://@omq-test-send-timeout")

      assert_raises(IO::TimeoutError) do
        2.times { push.send("fill") }
      end

      push.close
    end
  end

  it "does not raise when send completes within send_timeout" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://timeout-send-ok")
      push = OMQ::PUSH.new
      push.write_timeout = 1.second
      push.connect("inproc://timeout-send-ok")

      push.send("hello")
      msg = pull.receive
      assert_equal "hello", String.new(msg[0])

      push.close
      pull.close
    end
  end
end


describe "read_timeout" do
  it "raises IO::TimeoutError when PULL receive blocks longer than read_timeout" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.new
      pull.read_timeout = 20.milliseconds
      pull.bind("inproc://timeout-recv")

      push = OMQ::PUSH.connect("inproc://timeout-recv")

      assert_raises(IO::TimeoutError) { pull.receive }

      push.close
      pull.close
    end
  end

  it "does not raise when message arrives within read_timeout" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.new
      pull.read_timeout = 2.seconds
      pull.bind("inproc://timeout-recv-ok")

      push = OMQ::PUSH.connect("inproc://timeout-recv-ok")

      push.send("hello")
      msg = pull.receive
      assert_equal "hello", String.new(msg[0])

      push.close
      pull.close
    end
  end

  it "times out on SUB" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pub = OMQ::PUB.bind("inproc://timeout-sub")
      sub = OMQ::SUB.connect("inproc://timeout-sub")
      sub.subscribe("")
      sub.read_timeout = 20.milliseconds

      assert_raises(IO::TimeoutError) { sub.receive }

      sub.close
      pub.close
    end
  end

  it "times out on PAIR" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      a = OMQ::PAIR.bind("inproc://timeout-pair")
      b = OMQ::PAIR.connect("inproc://timeout-pair")
      b.read_timeout = 20.milliseconds

      assert_raises(IO::TimeoutError) { b.receive }

      a.close
      b.close
    end
  end

  it "times out on REP" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      rep = OMQ::REP.bind("inproc://timeout-rep")
      rep.read_timeout = 20.milliseconds

      assert_raises(IO::TimeoutError) { rep.receive }

      rep.close
    end
  end

  it "times out on DEALER" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      router = OMQ::ROUTER.bind("inproc://timeout-dealer")
      dealer = OMQ::DEALER.connect("inproc://timeout-dealer")
      dealer.read_timeout = 20.milliseconds

      assert_raises(IO::TimeoutError) { dealer.receive }

      dealer.close
      router.close
    end
  end
end
