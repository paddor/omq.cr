require "../../src/omq"

endpoint = ARGV[0]? || "tcp://*:5556"

pub = OMQ::PUB.new
pub.bind(endpoint)
puts "Publisher on #{endpoint} — broadcasting every second ..."

begin
  i = 0
  loop do
    i += 1
    pub << "weather.nyc #{rand(60..100)}F"
    pub << "weather.sfo #{rand(50..80)}F"
    pub << "sports.nba score #{rand(80..120)}-#{rand(80..120)}"
    puts "  broadcast ##{i}"
    sleep 1.second
  end
ensure
  pub.close
end
