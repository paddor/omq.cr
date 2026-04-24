require "../../src/omq"

endpoint = ARGV[0]? || "tcp://*:5555"

rep = OMQ::REP.new
rep.bind(endpoint)
puts "Server on #{endpoint} ..."

begin
  loop do
    msg = rep.receive
    puts "  ← #{msg.map { |p| String.new(p) }.inspect}"
    rep << msg.map { |p| String.new(p).upcase.to_slice }
  end
ensure
  rep.close
end
