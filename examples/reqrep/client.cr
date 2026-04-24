require "../../src/omq"

endpoint = ARGV[0]? || "tcp://localhost:5555"

req = OMQ::REQ.new(endpoint)
puts "Client connected to #{endpoint.lchop('>')}"

begin
  loop do
    STDOUT.print "> "
    STDOUT.flush
    input = STDIN.gets
    break if input.nil?
    input = input.chomp
    break if input.empty?

    req << input
    reply = req.receive
    puts "  → #{reply.map { |p| String.new(p) }.inspect}"
  end
ensure
  req.close
end
