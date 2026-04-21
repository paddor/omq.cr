module OMQ
  # Routing strategies decide how the socket multiplexes multiple peers:
  # who we send to, who we receive from, and in what order. Each socket
  # type plugs in exactly one strategy; see `Routing::Push`, `Routing::Pull`,
  # etc. for concrete shapes.
  module Routing
    abstract class Strategy
      # Attach a newly-opened pipe (accepted or connected).
      abstract def attach(pipe : Pipe) : Nil

      # Tear down all internal fibers and peers. Must be idempotent.
      abstract def close : Nil

      # Stop accepting new application sends so the strategy's pumps can
      # drain into per-pipe queues. Default: same as `#close`. Send-side
      # strategies override to separate "stop accepting" from "tear down".
      def close_send : Nil
        close
      end

      # Block until the strategy's send pumps have finished moving all
      # buffered messages into pipe queues (or `span` elapses). Default:
      # no-op (nothing to drain). Returns `true` on drain, `false` on
      # timeout.
      def await_drained(span : Time::Span?) : Bool
        true
      end
    end
  end
end
