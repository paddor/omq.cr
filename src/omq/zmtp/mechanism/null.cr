module OMQ::ZMTP
  # NULL mechanism: no crypto, no auth. Each side sends READY, reads READY.
  class Mechanism::Null < Mechanism
    NAME = "NULL"

    def name : String
      NAME
    end

    def handshake(io : IO, *, local_socket_type : String, local_identity : Bytes, as_server : Bool) : Hash(String, Bytes)
      payload = Command.ready(local_socket_type, local_identity)
      Frame.encode(io, payload, command: true)
      io.flush if io.responds_to?(:flush)

      frame_payload, _more, is_command = Frame.decode(io)
      raise ProtocolError.new("expected COMMAND frame in handshake") unless is_command
      name, body = Command.parse(frame_payload)
      raise ProtocolError.new("expected READY, got #{name}") unless name == "READY"
      Command.parse_properties(body)
    end
  end
end
