require "./system_test_helper"
require "../../src/omq/radio_dish"


describe "Crystal DISH ↔ Ruby RADIO over TCP" do
  it "receives only messages for the joined group" do
    if OMQ::SystemTestHelper.ruby_bin.nil?
      skip "ruby + omq gem not installed (set OMQ_RUBY_BIN to override)"
    end

    OMQ::SystemTestHelper.with_timeout(5.seconds) do
      process, port = OMQ::SystemTestHelper.spawn_ruby_with_port("radio_publisher.rb", ["weather", "3"])

      begin
        dish = OMQ::DISH.new
        dish.connect("tcp://127.0.0.1:#{port}")
        dish.join("weather")

        expected = ["msg-0", "msg-1", "msg-2"]
        expected.each do |want|
          msg = dish.receive
          assert_equal "weather", String.new(msg[0])
          assert_equal want,      String.new(msg[1])
        end

        dish.close
      ensure
        OMQ::SystemTestHelper.shutdown(process)
      end
    end
  end
end
