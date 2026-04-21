# frozen_string_literal: true

# RADIO publisher for Crystal ↔ Ruby RADIO/DISH interop test.
#
# Usage: radio_publisher.rb <group> <count>
#
# Binds, prints PORT, waits for a DISH peer to attach, then publishes
# <count> messages on <group> ("msg-<i>") plus a few on the sentinel
# group "ignore" that DISH should filter out.

require "omq"
require "omq/radio_dish"
require "async"

$stdout.sync = true

group = ARGV[0] || "weather"
count = (ARGV[1] || "5").to_i

Async do |task|
  radio = OMQ::RADIO.new
  port  = radio.bind("tcp://127.0.0.1:0")
  puts "PORT=#{port}"

  watchdog = task.async do
    $stdin.read
    task.stop
  end

  radio.peer_connected
  sleep 0.1

  count.times do |i|
    radio.publish("ignore", "dropped-#{i}")
    radio.publish(group,    "msg-#{i}")
  end

  sleep
ensure
  radio&.close
  watchdog&.stop
end
