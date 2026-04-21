# frozen_string_literal: true

# REP server for Crystal ↔ Ruby REQ/REP interop test.
#
# Binds on an ephemeral TCP port, prints "PORT=<n>\n" so the Crystal
# harness knows where to connect, then loops: receive a single-frame
# request, reply with the same frame uppercased. Exits on stdin EOF.

require "omq"
require "async"

$stdout.sync = true

Async do |task|
  rep = OMQ::REP.new
  port = rep.bind("tcp://127.0.0.1:0")
  puts "PORT=#{port}"

  watchdog = task.async do
    $stdin.read
    task.stop
  end

  loop do
    msg = rep.receive
    rep << msg.map(&:upcase)
  end
ensure
  rep&.close
  watchdog&.stop
end
