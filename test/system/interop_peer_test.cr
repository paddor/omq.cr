require "./system_test_helper"
require "../../src/omq/peer"


describe "Crystal PEER ↔ Ruby PEER over TCP" do
  it "round-trips an addressed message via routing IDs" do
    if OMQ::SystemTestHelper.ruby_bin.nil?
      skip "ruby + omq gem not installed (set OMQ_RUBY_BIN to override)"
    end

    OMQ::SystemTestHelper.with_timeout(5.seconds) do
      process, endpoint = OMQ::SystemTestHelper.spawn_ruby_with_endpoint("peer_echo.rb")

      begin
        peer = OMQ::PEER.new
        peer.connect(endpoint)

        # Wait for the bind-side (Ruby) peer to assign us a routing ID
        # locally on our own side too. We discover the peer's ID by
        # polling our own #peer_routing_ids.
        ids = peer.peer_routing_ids
        while ids.empty?
          Fiber.yield
          ids = peer.peer_routing_ids
        end
        remote_id = ids[0]

        peer.send_to(remote_id, "hello")
        reply = peer.receive
        assert_equal "HELLO", String.new(reply[1])

        peer.close
      ensure
        OMQ::SystemTestHelper.shutdown(process)
      end
    end
  end
end
