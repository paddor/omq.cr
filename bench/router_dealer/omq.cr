require "../bench_helper"

# ROUTER/DEALER throughput: DEALERs send, ROUTER receives.
OMQ::BenchHelper.run("ROUTER/DEALER", dir: __DIR__, peer_counts: [3]) do |transport, ep, peers, payload|
  router = OMQ::ROUTER.new
  router.bind(ep)
  ep = OMQ::BenchHelper.resolve_endpoint(transport, ep, router)

  dealers = Array(OMQ::DEALER).new(peers) do |i|
    d = OMQ::DEALER.new
    d.identity = "d#{i}"
    d.connect(ep)
    d
  end

  OMQ::BenchHelper.wait_connected(router, expected: peers)
  dealers.each { |d| OMQ::BenchHelper.wait_connected(d) }

  burst = ->(k : Int64) do
    per = Math.max(k // dealers.size, 1_i64)
    done = Channel(Nil).new(dealers.size)
    dealers.each do |d|
      spawn do
        per.times { d.send(payload) }
        done.send(nil)
      end
    end
    (per * dealers.size).times { router.receive }
    dealers.size.times { done.receive }
  end

  begin
    OMQ::BenchHelper.measure_best_of(payload, align: dealers.size, &burst)
  ensure
    dealers.each(&.close)
    router.close
  end
end
