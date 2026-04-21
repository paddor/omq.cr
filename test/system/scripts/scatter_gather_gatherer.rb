# frozen_string_literal: true

# GATHER server for Crystal ↔ Ruby SCATTER/GATHER interop test.
#
# Binds, prints PORT, prints every received single-frame message on its
# own stdout line until EOF on stdin.

require "omq"
require "omq/scatter_gather"
require "async"

$stdout.sync = true

Async do |task|
  gather = OMQ::GATHER.new
  port   = gather.bind("tcp://127.0.0.1:0")
  puts "PORT=#{port}"

  watchdog = task.async do
    $stdin.read
    task.stop
  end

  loop do
    msg = gather.receive
    puts "RECV=#{msg[0]}"
  end
ensure
  gather&.close
  watchdog&.stop
end
