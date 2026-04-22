# frozen_string_literal: true

# SERVER for Crystal ↔ Ruby CLIENT/SERVER interop test.
#
# Binds, prints ENDPOINT, echoes each received frame back uppercased via
# send_to so the reply is routed to the originating CLIENT.

require "omq"
require "omq/client_server"
require "async"

$stdout.sync = true

Async do |task|
  server = OMQ::SERVER.new
  endpoint = server.bind("tcp://127.0.0.1:0")
  puts "ENDPOINT=#{endpoint}"

  watchdog = task.async do
    $stdin.read
    task.stop
  end

  loop do
    msg = server.receive
    routing_id, body = msg[0], msg[1]
    server.send_to(routing_id, body.upcase)
  end
ensure
  server&.close
  watchdog&.stop
end
