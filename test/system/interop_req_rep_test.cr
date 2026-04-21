require "./system_test_helper"


describe "Ruby REP ↔ Crystal REQ over TCP" do
  it "round-trips a string and gets it back uppercased" do
    if OMQ::SystemTestHelper.ruby_bin.nil?
      skip "ruby + omq gem not installed (set OMQ_RUBY_BIN to override)"
    end

    OMQ::SystemTestHelper.with_timeout(5.seconds) do
      process, port = OMQ::SystemTestHelper.spawn_ruby_with_port("req_rep_server.rb")

      begin
        req = OMQ::REQ.new
        req.connect("tcp://127.0.0.1:#{port}")

        req.send("hello")
        reply = req.receive
        assert_equal "HELLO", String.new(reply[0])

        req.send("ping")
        reply = req.receive
        assert_equal "PING", String.new(reply[0])

        req.close
      ensure
        OMQ::SystemTestHelper.shutdown(process)
      end
    end
  end
end
