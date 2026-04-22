require "./system_test_helper"


describe "Ruby PULL ↔ Crystal PUSH over TCP" do
  it "pushes N messages and the Ruby puller sees them in order" do
    if OMQ::SystemTestHelper.ruby_bin.nil?
      skip "ruby + omq gem not installed (set OMQ_RUBY_BIN to override)"
    end

    OMQ::SystemTestHelper.with_timeout(5.seconds) do
      process, endpoint = OMQ::SystemTestHelper.spawn_ruby_with_endpoint("push_pull_puller.rb")

      begin
        push = OMQ::PUSH.new
        push.connect(endpoint)

        n = 10
        n.times { |i| push.send("work-#{i}") }

        received = OMQ::SystemTestHelper.read_lines(process, n)
        assert_equal n, received.size
        n.times do |i|
          assert_equal "work-#{i}", received[i]
        end

        push.linger = 2.seconds
        push.close
      ensure
        OMQ::SystemTestHelper.shutdown(process)
      end
    end
  end
end
