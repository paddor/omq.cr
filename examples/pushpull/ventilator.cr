require "../../src/omq"

endpoint = ARGV[0]? || "tcp://localhost:5557"

push = OMQ::PUSH.new(endpoint)
puts "Ventilator on #{endpoint.lchop('>')} — type tasks, one per line"

begin
  loop do
    STDOUT.print "> "
    STDOUT.flush
    input = STDIN.gets
    break if input.nil?
    input = input.chomp
    break if input.empty?

    push << input
    puts "  sent"
  end
ensure
  push.close
end
