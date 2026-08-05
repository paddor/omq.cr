# frozen_string_literal: true

require "omq"
require "omq/zstd"

$stdout.sync = true

endpoint = ARGV.fetch(0)
mode = ARGV[1] || "plain"
count = Integer(ARGV[2] || 10)

def payload(mode, i)
  case mode
  when "dict"
    (%({"event":"login","user":"user_#{i}","region":"us-east-1","status":200}) * 20).b
  when "auto_dict"
    body = "field=#{i % 16} region=us-east-1 status=200 " * 45
    %({"event":"login","user":"user_#{i % 16}","payload":"#{body}"}).b
  else
    "zstd-work-#{i}".b
  end
end

def training_dict
  trainer = Zrip::DictTrainer.new(2048)
  40.times { |i| trainer.add_sample(payload("dict", i)) }
  trainer.train
end

push = OMQ::PUSH.new
case mode
when "dict"
  push.connect(endpoint, dict: training_dict)
when "auto_dict"
  push.connect(endpoint, auto_dict: { capacity: 2048 })
else
  push.connect(endpoint)
end

puts "READY"
count.times { |i| push << [payload(mode, i)] }
push.close
