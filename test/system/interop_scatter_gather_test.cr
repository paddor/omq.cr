require "./system_test_helper"
require "../../src/omq/scatter_gather"


describe "Crystal SCATTER ↔ Ruby GATHER over TCP" do
  it "delivers single-frame messages to the Ruby GATHER" do
    if OMQ::SystemTestHelper.ruby_bin.nil?
      skip "ruby + omq gem not installed (set OMQ_RUBY_BIN to override)"
    end

    OMQ::SystemTestHelper.with_timeout(5.seconds) do
      process, endpoint = OMQ::SystemTestHelper.spawn_ruby_with_endpoint("scatter_gather_gatherer.rb")

      begin
        scatter = OMQ::SCATTER.new
        scatter.connect(endpoint)

        scatter.send("one")
        scatter.send("two")
        scatter.send("three")

        lines = OMQ::SystemTestHelper.read_lines(process, 3)
        assert_equal ["RECV=one", "RECV=two", "RECV=three"], lines

        scatter.close
      ensure
        OMQ::SystemTestHelper.shutdown(process)
      end
    end
  end
end
