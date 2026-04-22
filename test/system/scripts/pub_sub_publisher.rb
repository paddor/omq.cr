# frozen_string_literal: true

# PUB server for Crystal ↔ Ruby PUB/SUB interop test.
#
# Usage: pub_sub_publisher.rb <topic> <n>
#
# Binds, prints ENDPOINT=<uri>, waits for a subscriber to attach (peer_count >
# 0), then publishes <n> messages of the form "<topic> <i>" with a small
# gap so the subscriber has time to finish its local subscribe before the
# first frame hits the wire. Exits on EOF.

require "omq"
require "async"

$stdout.sync = true

topic = ARGV[0] || "news"
count = (ARGV[1] || "10").to_i

Async do |task|
  pub = OMQ::PUB.new
  endpoint = pub.bind("tcp://127.0.0.1:0")
  puts "ENDPOINT=#{endpoint}"

  watchdog = task.async do
    $stdin.read
    task.stop
  end

  # Wait for at least one subscriber before publishing — raw PUB drops
  # messages to absent peers and we don't want to race the handshake.
  pub.peer_connected
  # A further tick lets the SUB's local subscribe() apply before we
  # start publishing — without this the very first frame is often
  # filtered out by the subscriber.
  sleep 0.1

  count.times do |i|
    pub << "#{topic} #{i}"
  end

  # Keep the process alive until the harness decides we're done so
  # close-time LINGER doesn't truncate the tail.
  sleep
ensure
  pub&.close
  watchdog&.stop
end
