# frozen_string_literal: true

# PUB server for Crystal ↔ Ruby PUB/SUB interop test.
#
# Usage: pub_sub_publisher.rb <topic> <n>
#
# Binds, prints ENDPOINT=<uri>, waits for SUBSCRIBE, then publishes <n>
# messages of the form "<topic> <i>". Exits on EOF.

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

  pub.subscriber_joined.wait

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
