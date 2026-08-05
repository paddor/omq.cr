# frozen_string_literal: true

require "omq"
require "async"
require "protocol/zmtp/mechanism/curve"
require "rbnacl"

$stdout.sync = true

server_pub = [ARGV.fetch(0)].pack("H*")
server_sec = [ARGV.fetch(1)].pack("H*")
count = Integer(ARGV[2] || 3)

Async do |task|
  rep = OMQ::REP.new
  rep.mechanism = Protocol::ZMTP::Mechanism::Curve.server(
    public_key: server_pub,
    secret_key: server_sec,
    crypto: RbNaCl,
  )
  endpoint = rep.bind("tcp://127.0.0.1:0")
  puts "ENDPOINT=#{endpoint}"

  count.times do
    msg = rep.receive
    rep << msg.map(&:upcase)
  end
ensure
  rep&.close
  task&.stop
end
