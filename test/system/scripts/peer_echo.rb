# frozen_string_literal: true

# PEER echo server for Crystal ↔ Ruby PEER interop test.
#
# Binds, prints ENDPOINT, echoes each received frame back uppercased via
# send_to using the routing ID surfaced as the first frame.

require "omq"
require "omq/peer"
require "async"

$stdout.sync = true

Async do |task|
  peer = OMQ::PEER.new
  endpoint = peer.bind("tcp://127.0.0.1:0")
  puts "ENDPOINT=#{endpoint}"

  watchdog = task.async do
    $stdin.read
    task.stop
  end

  loop do
    msg = peer.receive
    routing_id, body = msg[0], msg[1]
    peer.send_to(routing_id, body.upcase)
  end
ensure
  peer&.close
  watchdog&.stop
end
