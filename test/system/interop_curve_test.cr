require "./system_test_helper"
require "../../src/omq/curve"

private def curve_interop_available?
  OMQ::SystemTestHelper.ruby_can_require?("protocol/zmtp/mechanism/curve") &&
    OMQ::SystemTestHelper.ruby_can_require?("rbnacl")
end

private def curve_keypair
  sk = Natron::PrivateKey.generate
  {sk.public_key.bytes, sk.bytes}
end

private def hex(bytes : Bytes) : String
  String.build do |io|
    bytes.each { |b| io << b.to_s(16).rjust(2, '0') }
  end
end

describe "Crystal CURVE REP ↔ Ruby REQ over TCP" do
  it "round-trips encrypted messages and passes peer context to the authenticator" do
    skip "ruby + CURVE dependencies not installed" unless curve_interop_available?

    OMQ::SystemTestHelper.with_timeout(5.seconds) do
      server_pub, server_sec = curve_keypair
      client_pub, client_sec = curve_keypair
      seen = Channel(OMQ::ZMTP::Mechanism::Curve::PeerInfo).new(1)

      authenticator = ->(peer : OMQ::ZMTP::Mechanism::Curve::PeerInfo) {
        seen.send(peer)
        peer.public_key == client_pub
      }

      rep = OMQ::REP.new
      rep.read_timeout = 2.seconds
      rep.mechanism = OMQ::ZMTP::Mechanism::Curve.server(
        public_key: server_pub,
        secret_key: server_sec,
        authenticator: authenticator,
      )
      rep.bind("tcp://127.0.0.1:0")
      endpoint = "tcp://127.0.0.1:#{rep.port.not_nil!}"

      ruby = OMQ::SystemTestHelper.ruby_bin.not_nil!
      script = File.join(OMQ::SystemTestHelper::SCRIPTS_DIR, "curve_req_client.rb")
      process = Process.new(
        ruby,
        [script, endpoint, hex(server_pub), hex(client_pub), hex(client_sec), "3", "ruby-client"],
        input: :pipe,
        output: :pipe,
        error: :inherit,
      )

      begin
        assert_equal "READY", process.output.gets.try(&.chomp)

        3.times do |i|
          msg = rep.receive
          assert_equal "ruby-curve-#{i}", String.new(msg[0])
          rep.send(msg.map { |part| String.new(part).upcase.to_slice })
        end

        replies = OMQ::SystemTestHelper.read_lines(process, 3)
        assert_equal ["RUBY-CURVE-0", "RUBY-CURVE-1", "RUBY-CURVE-2"], replies

        peer = seen.receive
        assert_equal client_pub, peer.public_key
        assert_equal "ruby-client", String.new(peer.identity.not_nil!)
        assert peer.peer_address.not_nil!.includes?("127.0.0.1")
      ensure
        OMQ::SystemTestHelper.shutdown(process)
        rep.close
      end
    end
  end
end

describe "Ruby CURVE REP ↔ Crystal REQ over TCP" do
  it "round-trips encrypted messages" do
    skip "ruby + CURVE dependencies not installed" unless curve_interop_available?

    OMQ::SystemTestHelper.with_timeout(5.seconds) do
      server_pub, server_sec = curve_keypair
      client_pub, client_sec = curve_keypair

      process, endpoint = OMQ::SystemTestHelper.spawn_ruby_with_endpoint(
        "curve_rep_server.rb",
        [hex(server_pub), hex(server_sec), "3"],
      )

      begin
        req = OMQ::REQ.new
        req.mechanism = OMQ::ZMTP::Mechanism::Curve.client(
          server_key: server_pub,
          public_key: client_pub,
          secret_key: client_sec,
        )
        req.connect(endpoint)

        3.times do |i|
          req.send("crystal-curve-#{i}")
          assert_equal "CRYSTAL-CURVE-#{i}", String.new(req.receive[0])
        end

        req.close
      ensure
        OMQ::SystemTestHelper.shutdown(process)
      end
    end
  end
end
