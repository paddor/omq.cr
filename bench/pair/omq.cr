require "../bench_helper"

# PAIR exclusive 1-to-1 throughput.
OMQ::BenchHelper.run("PAIR", dir: __DIR__, peer_counts: [1]) do |transport, ep, _peers, payload|
  receiver = OMQ::PAIR.new
  receiver.bind(ep)
  ep = OMQ::BenchHelper.resolve_endpoint(transport, ep, receiver)

  sender = OMQ::PAIR.new
  sender.connect(ep)

  OMQ::BenchHelper.wait_connected(sender, receiver)

  burst = ->(k : Int64) do
    done = Channel(Nil).new(1)
    spawn do
      k.times { sender.send(payload) }
      done.send(nil)
    end
    k.times { receiver.receive }
    done.receive
  end

  begin
    OMQ::BenchHelper.measure_best_of(payload, &burst)
  ensure
    sender.close
    receiver.close
  end
end
