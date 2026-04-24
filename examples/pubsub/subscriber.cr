require "../../src/omq"

endpoint = ARGV[0]? || "tcp://localhost:5556"
prefix   = ARGV[1]? || ""

sub = OMQ::SUB.new(endpoint)
sub.subscribe(prefix)
label = prefix.empty? ? "\"\" (everything)" : prefix.inspect
puts "Subscribed to #{label} on #{endpoint.lchop('>')} ..."

begin
  loop do
    msg = sub.receive
    puts "  #{String.new(msg.first)}"
  end
ensure
  sub.close
end
