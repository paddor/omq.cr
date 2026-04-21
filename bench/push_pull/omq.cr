require "../bench_helper"

# PUSH/PULL sustained pipeline throughput.
OMQ::BenchHelper.run("PUSH/PULL", dir: __DIR__, peer_counts: [1, 3]) do |transport, ep, peers, payload|
  pull = OMQ::PULL.new
  pull.bind(ep)
  ep = OMQ::BenchHelper.resolve_endpoint(transport, ep, pull)

  pushes = Array(OMQ::PUSH).new(peers) do
    push = OMQ::PUSH.new
    push.connect(ep)
    push
  end

  OMQ::BenchHelper.wait_connected(pull, expected: peers)
  pushes.each { |p| OMQ::BenchHelper.wait_connected(p) }

  burst = ->(k : Int64) do
    per = Math.max(k // pushes.size, 1_i64)
    done = Channel(Nil).new(pushes.size)
    pushes.each do |push|
      spawn do
        per.times { push.send(payload) }
        done.send(nil)
      end
    end
    (per * pushes.size).times { pull.receive }
    pushes.size.times { done.receive }
  end

  begin
    OMQ::BenchHelper.measure_best_of(payload, align: pushes.size, &burst)
  ensure
    pushes.each(&.close)
    pull.close
  end
end
