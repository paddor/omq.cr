# frozen_string_literal: true

require "omq"
require "omq/lz4"
require "async"

$stdout.sync = true

Async do |task|
  pull = OMQ::PULL.new
  endpoint = pull.bind("lz4+tcp://127.0.0.1:0")
  puts "ENDPOINT=#{endpoint}"

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
