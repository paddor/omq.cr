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
    end
  end
end
