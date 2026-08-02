require "../test_helper"

describe "recv pump fairness" do
  it "interleaves messages from two fast IPC peers" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      endpoint = "ipc://@omq-test-fairness-#{Process.pid}"
      pull = OMQ::PULL.bind(endpoint)
      push_a = OMQ::PUSH.connect(endpoint)
      push_b = OMQ::PUSH.connect(endpoint)
      OMQ::TestHelper.wait_until { pull.peer_count == 2 && push_a.peer_count == 1 && push_b.peer_count == 1 }

      per_peer = 200
      done = Channel(Nil).new(2)
      spawn do
        per_peer.times { push_a.send("A") }
        done.send(nil)
      end
      spawn do
        per_peer.times { push_b.send("B") }
        done.send(nil)
      end

      received = [] of String
      (per_peer * 2).times { received << String.new(pull.receive[0]) }
      2.times { done.receive }

      assert_equal per_peer, received.count("A")
      assert_equal per_peer, received.count("B")
      first_window = received.first(OMQ::RECV_FAIRNESS_MESSAGES * 3)
      assert_includes first_window, "A"
      assert_includes first_window, "B"

      push_a.close
      push_b.close
      pull.close
    end
  end

  it "does not starve a small-message peer behind large messages" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      endpoint = "ipc://@omq-test-fairness-bytes-#{Process.pid}"
      pull = OMQ::PULL.bind(endpoint)
      push_a = OMQ::PUSH.connect(endpoint)
      push_b = OMQ::PUSH.connect(endpoint)
      OMQ::TestHelper.wait_until { pull.peer_count == 2 && push_a.peer_count == 1 && push_b.peer_count == 1 }

      big = Bytes.new(512 * 1024, 0x58_u8)
      big_count = 10
      small_count = 10
      done = Channel(Nil).new(2)
      spawn do
        big_count.times { push_a.send(big) }
        done.send(nil)
      end
      spawn do
        small_count.times { push_b.send("y") }
        done.send(nil)
      end

      received = [] of UInt8
      (big_count + small_count).times { received << pull.receive[0][0] }
      2.times { done.receive }

      assert_equal big_count, received.count(0x58_u8)
      assert_equal small_count, received.count('y'.ord.to_u8)
      assert_includes received.first(big_count), 'y'.ord.to_u8

      push_a.close
      push_b.close
      pull.close
    end
  end

  it "preserves per-connection message ordering" do
    OMQ::TestHelper.with_timeout(5.seconds) do
      endpoint = "ipc://@omq-test-fairness-order-#{Process.pid}"
      pull = OMQ::PULL.bind(endpoint)
      push_a = OMQ::PUSH.connect(endpoint)
      push_b = OMQ::PUSH.connect(endpoint)
      OMQ::TestHelper.wait_until { pull.peer_count == 2 && push_a.peer_count == 1 && push_b.peer_count == 1 }

      per_peer = 200
      done = Channel(Nil).new(2)
      spawn do
        per_peer.times { |i| push_a.send("A-#{i}") }
        done.send(nil)
      end
      spawn do
        per_peer.times { |i| push_b.send("B-#{i}") }
        done.send(nil)
      end

      received = [] of String
      (per_peer * 2).times { received << String.new(pull.receive[0]) }
      2.times { done.receive }

      assert_equal (0...per_peer).map { |i| "A-#{i}" }, received.select(&.starts_with?("A-"))
      assert_equal (0...per_peer).map { |i| "B-#{i}" }, received.select(&.starts_with?("B-"))

      push_a.close
      push_b.close
      pull.close
    end
  end
end
