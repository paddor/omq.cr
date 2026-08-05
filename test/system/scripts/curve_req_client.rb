# frozen_string_literal: true

require "omq"
require "protocol/zmtp/mechanism/curve"
require "rbnacl"

$stdout.sync = true

endpoint = ARGV.fetch(0)
server_pub = [ARGV.fetch(1)].pack("H*")
client_pub = [ARGV.fetch(2)].pack("H*")
client_sec = [ARGV.fetch(3)].pack("H*")
count = Integer(ARGV[4] || 3)
identity = ARGV[5]

req = OMQ::REQ.new
req.identity = identity if identity && !identity.empty?
req.mechanism = Protocol::ZMTP::Mechanism::Curve.client(
  server_key: server_pub,
  public_key: client_pub,
  secret_key: client_sec,
  crypto: RbNaCl,
)
req.connect(endpoint)

puts "READY"
count.times do |i|
  req << ["ruby-curve-#{i}"]
  puts req.receive.first
end
req.close
