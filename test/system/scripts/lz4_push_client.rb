# frozen_string_literal: true

require "omq"
require "omq/lz4"

$stdout.sync = true

endpoint = ARGV.fetch(0)
mode = ARGV[1] || "plain"
count = Integer(ARGV[2] || 10)

DICT = ("event=login user=alice payload=" * 10).b

def payload(mode, i)
  case mode
  when "dict"
    ("event=login user=alice payload=#{i}" * 8).b
  when "auto_dict"
    %({"event":"login","user":"user_#{i}","ts":"2026-08-03T00:00:00.#{i}Z","region":"us-east-1","status":200}).b
  else
    "lz4-work-#{i}".b
  end
end

push = OMQ::PUSH.new
case mode
when "dict"
  push.connect(endpoint, dict: DICT)
when "auto_dict"
  push.connect(endpoint, auto_dict: { capacity: 2048, trigger: 5 })
else
  push.connect(endpoint)
end

puts "READY"
count.times { |i| push << [payload(mode, i)] }
push.close
