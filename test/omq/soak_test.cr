require "../test_helper"
require "../../src/omq/curve"

private def soak_zstd_endpoint(socket : OMQ::Socket) : String
  "zstd+tcp://127.0.0.1:#{socket.port.not_nil!}"
end

private def soak_bind_curve_pull(port : Int32, keys : OMQ::Curve::KeyPair) : OMQ::PULL
  deadline = Time.instant + 2.seconds
  loop do
    pull = OMQ::PULL.new(linger: 0.seconds, read_timeout: 1.second)
    pull.mechanism = OMQ::ZMTP::Mechanism::Curve.server(
      public_key: keys.public_key,
      secret_key: keys.secret_key,
    )

    begin
      pull.bind("tcp://127.0.0.1:#{port}")
      return pull
    rescue ex : IO::Error
      pull.close
      raise ex if Time.instant >= deadline
      sleep 1.millisecond
    end
  end
end

describe "bounded soak coverage" do
  it "keeps PUSH/PULL live through repeated TCP reconnect churn" do
    OMQ::TestHelper.with_timeout(8.seconds) do
      pull = OMQ::PULL.bind("tcp://127.0.0.1:0", linger: 0.seconds, read_timeout: 1.second)
      port = pull.port.not_nil!
      push = OMQ::PUSH.connect(
        "tcp://127.0.0.1:#{port}",
        linger: 0.seconds,
        reconnect_interval: 10.milliseconds,
        write_timeout: 1.second,
      )

      12.times do |i|
        OMQ::TestHelper.wait_until { push.peer_count > 0 && pull.peer_count > 0 }
        payload = "plain-cycle-#{i}"
        push.send(payload)
        assert_equal payload, String.new(pull.receive[0])

        next if i == 11

        pull.close
        OMQ::TestHelper.wait_disconnected(push)
        pull = OMQ::TestHelper.restart_bind_tcp(OMQ::PULL, port)
        pull.read_timeout = 1.second
      end

      push.close
      pull.close
    end
  end

  it "keeps zstd PUB/SUB fanout live while subscribers churn" do
    OMQ::TestHelper.with_timeout(8.seconds) do
      pub = OMQ::PUB.bind(
        "zstd+tcp://127.0.0.1:0",
        linger: 0.seconds,
        zstd_auto_dict: OMQ::Transport::ZstdTcp::AutoDict.new(capacity: 2048, max_samples: 5),
      )
      stable = OMQ::SUB.connect(
        soak_zstd_endpoint(pub),
        subscribe: "topic",
        linger: 0.seconds,
        read_timeout: 1.second,
        recv_hwm: 128,
      )
      pub.subscriber_joined.receive

      12.times do |i|
        late = OMQ::SUB.connect(
          soak_zstd_endpoint(pub),
          subscribe: "topic",
          linger: 0.seconds,
          read_timeout: 1.second,
          recv_hwm: 16,
        )
        pub.subscriber_joined.receive

        payload = (%({"seq":#{i},"kind":"zstd-churn","value":"}) + ("A" * 512) + %("})).to_slice
        pub.send(["topic".to_slice, payload])

        assert_equal ["topic".to_slice, payload], stable.receive
        assert_equal ["topic".to_slice, payload], late.receive

        late.close
        OMQ::TestHelper.wait_until(2.seconds) { pub.peer_count == 1 }
      end

      stable.close
      pub.close
    end
  end

  it "re-handshakes CURVE clients across repeated server restarts" do
    server_keys = OMQ::Curve::KeyPair.generate
    client_keys = OMQ::Curve::KeyPair.generate

    OMQ::TestHelper.with_timeout(8.seconds) do
      pull = soak_bind_curve_pull(0, server_keys)
      port = pull.port.not_nil!
      push = OMQ::PUSH.new(
        linger: 0.seconds,
        reconnect_interval: 10.milliseconds,
        write_timeout: 1.second,
      )
      push.mechanism = OMQ::ZMTP::Mechanism::Curve.client(
        server_key: server_keys.public_z85,
        public_key: client_keys.public_key,
        secret_key: client_keys.secret_z85,
      )
      push.connect("tcp://127.0.0.1:#{port}")

      8.times do |i|
        OMQ::TestHelper.wait_until { push.peer_count > 0 && pull.peer_count > 0 }
        payload = "curve-cycle-#{i}"
        push.send(payload)
        assert_equal payload, String.new(pull.receive[0])

        next if i == 7

        pull.close
        OMQ::TestHelper.wait_disconnected(push)
        pull = soak_bind_curve_pull(port, server_keys)
      end

      push.close
      pull.close
    end
  end
end
