require "../../src/omq"

endpoint = ARGV[0]? || "tcp://*:5557"
id       = ARGV[1]? || Process.pid.to_s

pull = OMQ::PULL.new
if endpoint.starts_with?(">")
  pull.connect(endpoint.lchop('>'))
else
  pull.bind(endpoint)
end
puts "Worker #{id} on #{endpoint} — waiting for tasks ..."

begin
  loop do
    msg = pull.receive
    puts "  [#{id}] got: #{msg.map { |p| String.new(p) }.inspect}"
  end
ensure
  pull.close
end
