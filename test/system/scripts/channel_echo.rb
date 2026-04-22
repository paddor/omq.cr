# frozen_string_literal: true

# CHANNEL echo server for Crystal ↔ Ruby CHANNEL interop test.
#
# Binds, prints ENDPOINT, echoes each received single-frame message back
# uppercased.

require "omq"
require "omq/channel"
require "async"

$stdout.sync = true

Async do |task|
  channel = OMQ::CHANNEL.new
  endpoint = channel.bind("tcp://127.0.0.1:0")
  puts "ENDPOINT=#{endpoint}"

  watchdog = task.async do
    $stdin.read
    task.stop
  end

  loop do
    msg = channel.receive
    channel << msg[0].upcase
  end
ensure
  channel&.close
  watchdog&.stop
end
