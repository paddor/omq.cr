require "../test_helper"
require "../../src/omq/curve"

describe "CURVE encryption" do

  def generate_keypair
    sk = Natron::PrivateKey.generate
    {sk.public_key.bytes, sk.bytes}
  end


  it "REQ/REP round-trips over TCP" do
    server_pub, server_sec = generate_keypair
    client_pub, client_sec = generate_keypair

    OMQ::TestHelper.with_timeout(3.seconds) do
      rep = OMQ::REP.new
      rep.mechanism = OMQ::ZMTP::Mechanism::Curve.server(public_key: server_pub, secret_key: server_sec)
      rep.bind("tcp://127.0.0.1:0")
      port = rep.port.not_nil!

      req = OMQ::REQ.new
      req.mechanism = OMQ::ZMTP::Mechanism::Curve.client(server_key: server_pub, public_key: client_pub, secret_key: client_sec)
      req.connect("tcp://127.0.0.1:#{port}")

      spawn do
        msg = rep.receive
        rep.send(msg.map { |p| String.new(p).upcase.to_slice })
      end

      req.send("hello")
      reply = req.receive
      assert_equal 1, reply.size
      assert_equal "HELLO", String.new(reply[0])

      req.close
      rep.close
    end
  end


  it "PUSH/PULL carries multi-frame messages encrypted" do
    server_pub, server_sec = generate_keypair

    OMQ::TestHelper.with_timeout(3.seconds) do
      pull = OMQ::PULL.new
      pull.mechanism = OMQ::ZMTP::Mechanism::Curve.server(public_key: server_pub, secret_key: server_sec)
      pull.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!

      push = OMQ::PUSH.new
      push.mechanism = OMQ::ZMTP::Mechanism::Curve.client(server_key: server_pub)
      push.connect("tcp://127.0.0.1:#{port}")

      push.send(["part-a", "part-b", "part-c"])
      msg = pull.receive
      assert_equal 3, msg.size
      assert_equal "part-a", String.new(msg[0])
      assert_equal "part-b", String.new(msg[1])
      assert_equal "part-c", String.new(msg[2])

      push.close
      pull.close
    end
  end


  it "rejects clients denied by the authenticator" do
    server_pub, server_sec = generate_keypair
    allowed_pub, _allowed_sec = generate_keypair
    denied_pub, denied_sec = generate_keypair

    OMQ::TestHelper.with_timeout(3.seconds) do
      authenticator = ->(client_pub : Bytes) {
        client_pub == allowed_pub
      }
      pull = OMQ::PULL.new
      pull.mechanism = OMQ::ZMTP::Mechanism::Curve.server(public_key: server_pub, secret_key: server_sec, authenticator: authenticator)
      pull.read_timeout = 500.milliseconds
      pull.bind("tcp://127.0.0.1:0")
      port = pull.port.not_nil!

      push = OMQ::PUSH.new
      push.mechanism = OMQ::ZMTP::Mechanism::Curve.client(server_key: server_pub, public_key: denied_pub, secret_key: denied_sec)
      push.connect("tcp://127.0.0.1:#{port}")

      push.send("hello")
      assert_raises(IO::TimeoutError) { pull.receive }

      spawn pull.close
      spawn push.close
    end
  end
end
