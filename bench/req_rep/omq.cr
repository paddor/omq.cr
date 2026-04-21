require "../bench_helper"

# REQ/REP synchronous roundtrip throughput.
OMQ::BenchHelper.run("REQ/REP", dir: __DIR__, peer_counts: [1]) do |transport, ep, _peers, payload|
  rep = OMQ::REP.new
  rep.bind(ep)
  ep = OMQ::BenchHelper.resolve_endpoint(transport, ep, rep)

  req = OMQ::REQ.new
  req.connect(ep)

  OMQ::BenchHelper.wait_connected(req, rep)

  spawn do
    loop do
      msg = rep.receive? || break
      rep.send(msg)
    end
  end

  burst = ->(k : Int64) do
    k.times do
      req.send(payload)
      req.receive
    end
  end

  begin
    OMQ::BenchHelper.measure_best_of(payload, &burst)
  ensure
    req.close
    rep.close
  end
end
