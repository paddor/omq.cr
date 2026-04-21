# frozen_string_literal: true

# PULL server for Crystal ↔ Ruby PUSH/PULL interop test.
#
# Binds, prints PORT=<n>, then echoes each received first-frame as a
# line on stdout. The Crystal harness reads N lines and closes stdin
# to tell us to exit.

require "omq"
require "async"

$stdout.sync = true

Async do |task|
  pull = OMQ::PULL.new
  port = pull.bind("tcp://127.0.0.1:0")
  puts "PORT=#{port}"

  watchdog = task.async do
    $stdin.read
    task.stop
  end

  loop do
    msg = pull.receive
    puts msg.first
  end
ensure
  pull&.close
  watchdog&.stop
end
