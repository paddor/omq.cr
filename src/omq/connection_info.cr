module OMQ
  struct ConnectionInfo
    getter id : UInt64
    getter endpoint : String
    getter socket_type : String
    getter peer_zmtp_minor : UInt8
    getter connected_at : Time
    @peer_identity : Bytes

    def initialize(
      @id : UInt64,
      @endpoint : String,
      @socket_type : String,
      peer_identity : Bytes,
      @peer_zmtp_minor : UInt8,
      @connected_at : Time,
    )
      @peer_identity = peer_identity.dup
    end

    def peer_identity : Bytes
      @peer_identity.dup
    end
  end
end
