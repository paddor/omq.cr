require "../test_helper"
require "../../src/omq/channel"
require "../../src/omq/client_server"
require "../../src/omq/scatter_gather"

describe "QueueReadable" do
  it "#dequeue returns the next message" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://qi-dequeue")
      push = OMQ::PUSH.connect("inproc://qi-dequeue")

      push.send("hello")

      assert_equal "hello", String.new(pull.dequeue[0])

      push.close
      pull.close
    end
  end

  it "#pop is an alias for #dequeue" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://qi-pop")
      push = OMQ::PUSH.connect("inproc://qi-pop")

      push.send("hello")

      assert_equal "hello", String.new(pull.pop[0])

      push.close
      pull.close
    end
  end

  it "#wait blocks indefinitely, ignoring read_timeout" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://qi-wait", read_timeout: 50.milliseconds)
      push = OMQ::PUSH.connect("inproc://qi-wait")

      spawn do
        sleep 100.milliseconds
        push.send("hello")
      end

      assert_equal "hello", String.new(pull.wait[0])

      push.close
      pull.close
    end
  end

  it "#dequeue accepts a timeout kwarg" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://qi-dequeue-timeout")

      assert_raises(IO::TimeoutError) { pull.dequeue(timeout: 50.milliseconds) }

      pull.close
    end
  end

  it "#each yields messages until the caller breaks" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://qi-each")
      push = OMQ::PUSH.connect("inproc://qi-each")

      push.send("a")
      push.send("b")
      push.send("c")

      received = [] of String
      pull.each do |msg|
        received << String.new(msg[0])
        break if received.size == 3
      end

      assert_equal %w[a b c], received

      push.close
      pull.close
    end
  end

  it "#each returns when read_timeout expires" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://qi-each-timeout", read_timeout: 50.milliseconds)
      push = OMQ::PUSH.connect("inproc://qi-each-timeout")

      push.send("a")
      push.send("b")

      received = [] of String
      pull.each { |msg| received << String.new(msg[0]) }

      assert_equal %w[a b], received

      push.close
      pull.close
    end
  end
end

describe "QueueWritable" do
  it "#enqueue sends a message" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://qi-enqueue")
      push = OMQ::PUSH.connect("inproc://qi-enqueue")

      push.enqueue("hello")

      assert_equal "hello", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end

  it "#enqueue sends multiple messages" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://qi-enqueue-multi")
      push = OMQ::PUSH.connect("inproc://qi-enqueue-multi")

      push.enqueue("a", "b", "c")

      assert_equal "a", String.new(pull.receive[0])
      assert_equal "b", String.new(pull.receive[0])
      assert_equal "c", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end

  it "#push is an alias for #enqueue" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      pull = OMQ::PULL.bind("inproc://qi-push")
      push = OMQ::PUSH.connect("inproc://qi-push")

      push.push("hello")

      assert_equal "hello", String.new(pull.receive[0])

      push.close
      pull.close
    end
  end

  it "#enqueue returns self for chaining" do
    pull = OMQ::PULL.bind("inproc://qi-chain")
    push = OMQ::PUSH.connect("inproc://qi-chain")

    assert_same push, push.enqueue("hello")

    push.close
    pull.close
  end
end

describe "Queue interface on draft sockets" do
  it "works on CHANNEL" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      a = OMQ::CHANNEL.bind("inproc://qi-channel")
      b = OMQ::CHANNEL.connect("inproc://qi-channel")

      a.enqueue("hello")

      assert_equal "hello", String.new(b.pop[0])

      a.close
      b.close
    end
  end

  it "works on SCATTER/GATHER" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      gather = OMQ::GATHER.bind("inproc://qi-scatter")
      scatter = OMQ::SCATTER.connect("inproc://qi-scatter")

      scatter.push("hello")

      assert_equal "hello", String.new(gather.dequeue[0])

      scatter.close
      gather.close
    end
  end

  it "works on CLIENT/SERVER readable side" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      server = OMQ::SERVER.bind("inproc://qi-client")
      client = OMQ::CLIENT.connect("inproc://qi-client")

      client.enqueue("hello")
      msg = server.dequeue

      assert_equal 2, msg.size
      assert_equal "hello", String.new(msg[1])

      client.close
      server.close
    end
  end
end
