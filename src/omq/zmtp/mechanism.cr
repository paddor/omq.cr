module OMQ::ZMTP
  # Security mechanism interface. Subclasses handle the mechanism-specific
  # handshake frames exchanged after the greeting.
  abstract class Mechanism
    abstract def name : String

    # Perform mechanism-specific handshake. By the time this is called,
    # both sides have sent and received greetings.
    #
    # Implementations send/receive READY (and for CURVE: HELLO/WELCOME/
    # INITIATE) via `io`, returning the remote peer's property map.
    abstract def handshake(io : IO, *, local_socket_type : String, local_identity : Bytes, as_server : Bool) : Hash(String, Bytes)
  end
end

require "./mechanism/null"
