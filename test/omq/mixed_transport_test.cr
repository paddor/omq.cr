require "../test_helper"

private def wait_connection_count(socket : OMQ::Socket, count : Int32, span : Time::Span = 2.seconds) : Nil
  OMQ::TestHelper.wait_until(span) { socket.peer_count >= count }
end

private def drain_count(socket) : Int32
  count = 0
  loop do
    socket.receive
    count += 1
  rescue IO::TimeoutError
    break
  end
  count
end

describe "mixed transports" do
  it "PUSH distributes across inproc and TCP peers" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      push = OMQ::PUSH.new
      push.bind("inproc://mixed-push")
      push.bind("tcp://127.0.0.1:0")
      tcp_port = push.port.not_nil!

      pull_inproc = OMQ::PULL.connect("inproc://mixed-push")
      push.send("inproc-only")
      assert_equal "inproc-only", String.new(pull_inproc.receive[0])

      pull_tcp = OMQ::PULL.connect("tcp://127.0.0.1:#{tcp_port}")
      wait_connection_count(push, 2)

      pull_inproc.read_timeout = 50.milliseconds
      pull_tcp.read_timeout = 50.milliseconds
      4.times { |i| push.send("mixed-#{i}") }

      received = drain_count(pull_inproc) + drain_count(pull_tcp)
      assert_equal 4, received

      push.close
      pull_inproc.close
      pull_tcp.close
    end
  end

  it "keeps the inproc peer working after TCP peer disconnects" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      push = OMQ::PUSH.new
      push.bind("inproc://mixed-revert")
      push.bind("tcp://127.0.0.1:0")
      tcp_port = push.port.not_nil!

      pull_inproc = OMQ::PULL.connect("inproc://mixed-revert")
      pull_tcp = OMQ::PULL.connect("tcp://127.0.0.1:#{tcp_port}")
      wait_connection_count(push, 2)

      pull_inproc.read_timeout = 50.milliseconds
      pull_tcp.read_timeout = 50.milliseconds
      2.times { |i| push.send("both-#{i}") }
      assert_equal 2, drain_count(pull_inproc) + drain_count(pull_tcp)

      pull_tcp.close
      OMQ::TestHelper.wait_until { push.peer_count == 1 }

      pull_inproc.read_timeout = nil
      push.send("inproc-again")
      assert_equal "inproc-again", String.new(pull_inproc.receive[0])

      push.close
      pull_inproc.close
    end
  end
end
