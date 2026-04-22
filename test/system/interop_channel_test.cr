require "./system_test_helper"
require "../../src/omq/channel"


describe "Crystal CHANNEL ↔ Ruby CHANNEL over TCP" do
  it "round-trips a single-frame message" do
    if OMQ::SystemTestHelper.ruby_bin.nil?
      skip "ruby + omq gem not installed (set OMQ_RUBY_BIN to override)"
    end

    OMQ::SystemTestHelper.with_timeout(5.seconds) do
      process, endpoint = OMQ::SystemTestHelper.spawn_ruby_with_endpoint("channel_echo.rb")

      begin
        channel = OMQ::CHANNEL.new
        channel.connect(endpoint)

        channel.send("hello")
        reply = channel.receive
        assert_equal "HELLO", String.new(reply[0])

        channel.close
      ensure
        OMQ::SystemTestHelper.shutdown(process)
      end
    end
  end
end
