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

    # True if this mechanism wraps every post-handshake frame in an
    # encrypted MESSAGE command. NULL returns false; CURVE returns true.
    def encrypted? : Bool
      false
    end

    # Encrypt one logical frame into a MESSAGE command body. The returned
    # bytes are the command payload (name-length + "MESSAGE" + short nonce
    # + ciphertext) — the caller frames it as a COMMAND frame. Only called
    # when `encrypted?` is true.
    def encrypt(payload : Bytes, *, more : Bool, command : Bool) : Bytes
      raise NotImplementedError.new("#{name} does not encrypt")
    end

    # Decrypt a MESSAGE command body back into `{plaintext, more?, command?}`.
    # Only called when `encrypted?` is true.
    def decrypt(body : Bytes) : {Bytes, Bool, Bool}
      raise NotImplementedError.new("#{name} does not decrypt")
    end
  end
end

require "./mechanism/null"
