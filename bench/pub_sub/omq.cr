require "../bench_helper"

# PUB/SUB fan-out throughput. PUB sends N messages; each SUB receives all N.
# SUB is configured with the empty-prefix subscription so no filter drops.
OMQ::BenchHelper.run("PUB/SUB", dir: __DIR__, peer_counts: [3]) do |transport, ep, peers, payload|
  pub = OMQ::PUB.new
  pub.bind(ep)
  ep = OMQ::BenchHelper.resolve_endpoint(transport, ep, pub)

  subs = Array(OMQ::SUB).new(peers) do
    sub = OMQ::SUB.new
    sub.subscribe("")
    sub.connect(ep)
    sub
  end

  OMQ::BenchHelper.wait_connected(pub, expected: peers)
  subs.each { |s| OMQ::BenchHelper.wait_connected(s) }

  burst = ->(k : Int64) do
    send_done = Channel(Nil).new(1)
    spawn do
      k.times { pub.send(payload) }
      send_done.send(nil)
    end
    recv_done = Channel(Nil).new(subs.size)
    subs.each do |s|
      spawn do
        k.times { s.receive }
        recv_done.send(nil)
      end
    end
    subs.size.times { recv_done.receive }
    send_done.receive
  end

  begin
    OMQ::BenchHelper.measure_best_of(payload, &burst)
  ensure
    subs.each(&.close)
    pub.close
  end
end
