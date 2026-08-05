module OMQ
  enum DisconnectReason
    PeerClosed
    LocalClose
    Handover
    Error
  end

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
      HandshakeSucceeded
      HandshakeFailed
      Closed
    end

    getter kind : Kind
    getter endpoint : String
    getter pipe : Pipe?
    getter error : Exception?
    getter connection : ConnectionInfo?
    getter reason : DisconnectReason?
    getter peer_address : String?
    getter at : Time

    def initialize(
      @kind : Kind,
      @endpoint : String,
      @pipe : Pipe? = nil,
      @error : Exception? = nil,
      @connection : ConnectionInfo? = nil,
      @reason : DisconnectReason? = nil,
      @peer_address : String? = nil,
    )
      @at = Time.utc
    end
  end
end
