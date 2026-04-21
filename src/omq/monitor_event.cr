module OMQ

  # Connection lifecycle event surfaced via `Socket#monitor`. A subscriber
  # iterates with `while ev = channel.receive?; …; end` — the channel is
  # closed when the socket closes.
  struct MonitorEvent

    enum Kind
      Listening
      Accepted
      Connected
      Disconnected
      ConnectDelayed
      ConnectRetried
      HandshakeFailed
      Closed
    end


    getter kind : Kind
    getter endpoint : String
    getter pipe : Pipe?
    getter error : Exception?
    getter at : Time


    def initialize(@kind : Kind, @endpoint : String, @pipe : Pipe? = nil, @error : Exception? = nil)
      @at = Time.utc
    end
  end
end
