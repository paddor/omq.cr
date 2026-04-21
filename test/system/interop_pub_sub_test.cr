require "./system_test_helper"


describe "Ruby PUB ↔ Crystal SUB over TCP" do
  it "subscribes to a topic and receives every matching message" do
    if OMQ::SystemTestHelper.ruby_bin.nil?
      skip "ruby + omq gem not installed (set OMQ_RUBY_BIN to override)"
    end

    OMQ::SystemTestHelper.with_timeout(8.seconds) do
      n = 5
      process, port = OMQ::SystemTestHelper.spawn_ruby_with_port("pub_sub_publisher.rb", ["news", n.to_s])

      begin
        sub = OMQ::SUB.new
        sub.recv_hwm = 1000
        sub.connect("tcp://127.0.0.1:#{port}")
        sub.subscribe("news")

        received = [] of String
        sub.read_timeout = 3.seconds
        n.times do
          msg = sub.receive
          received << String.new(msg[0])
        end

        assert_equal n, received.size
        n.times do |i|
          assert_equal "news #{i}", received[i]
        end

        sub.close
      ensure
        OMQ::SystemTestHelper.shutdown(process)
      end
    end
  end
end
