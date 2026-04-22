require "./system_test_helper"
require "../../src/omq/client_server"


describe "Crystal CLIENT ↔ Ruby SERVER over TCP" do
  it "round-trips a request and receives an uppercased reply" do
    if OMQ::SystemTestHelper.ruby_bin.nil?
      skip "ruby + omq gem not installed (set OMQ_RUBY_BIN to override)"
    end

    OMQ::SystemTestHelper.with_timeout(5.seconds) do
      process, endpoint = OMQ::SystemTestHelper.spawn_ruby_with_endpoint("client_server_server.rb")

      begin
        client = OMQ::CLIENT.new
        client.connect(endpoint)

        client.send("hello")
        reply = client.receive
        assert_equal "HELLO", String.new(reply[0])

        client.send("ping")
        reply = client.receive
        assert_equal "PING", String.new(reply[0])

        client.close
      ensure
        OMQ::SystemTestHelper.shutdown(process)
      end
    end
  end
end
