module OMQ::ZMTP
  # PLAIN mechanism (RFC 24): username/password authentication without
  # encryption. The post-handshake data path remains normal ZMTP frames.
  class Mechanism::Plain < Mechanism
    NAME = "PLAIN"

    def self.client(username : String, password : String) : Plain
      new(username: username, password: password, authenticator: nil, as_server: false)
    end

    def self.server(credentials : Hash(String, String)) : Plain
      server { |username, password| credentials[username]? == password }
    end

    def self.server(&authenticator : String, String -> Bool) : Plain
      new(username: nil, password: nil, authenticator: authenticator, as_server: true)
    end

    def initialize(
      *,
      username : String?,
      password : String?,
      @authenticator : Proc(String, String, Bool)?,
      @as_server : Bool,
    )
      @username = username
      @password = password
      validate_credential!("PLAIN username", username) if username
      validate_credential!("PLAIN password", password) if password
    end

    def name : String
      NAME
    end

    def handshake(
      io : IO,
      *,
      local_socket_type : String,
      local_identity : Bytes,
      as_server : Bool,
      peer_address : String? = nil,
    ) : Hash(String, Bytes)
      raise ProtocolError.new("PLAIN role mismatch") unless as_server == @as_server

      if @as_server
        server_handshake(io, local_socket_type, local_identity)
      else
        client_handshake(io, local_socket_type, local_identity)
      end
    end

    private def client_handshake(io : IO, local_socket_type : String, local_identity : Bytes) : Hash(String, Bytes)
      write_command(io, "HELLO", encode_hello(@username.not_nil!, @password.not_nil!))
      read_command(io, "WELCOME")

      write_command(io, "INITIATE", Command.properties(local_socket_type, local_identity))
      ready_body = read_command(io, "READY")
      Command.parse_properties(ready_body)
    end

    private def server_handshake(io : IO, local_socket_type : String, local_identity : Bytes) : Hash(String, Bytes)
      hello_body = read_command(io, "HELLO")
      username, password = decode_hello(hello_body)

      authenticator = @authenticator || raise ProtocolError.new("PLAIN server authenticator missing")
      unless authenticator.call(username, password)
        write_payload(io, Command.error("Authentication failed"))
        raise HandshakeFailed.new("PLAIN credentials rejected")
      end

      write_command(io, "WELCOME")
      initiate_body = read_command(io, "INITIATE")
      peer_props = Command.parse_properties(initiate_body)
      write_payload(io, Command.ready(local_socket_type, local_identity))
      peer_props
    end

    private def write_command(io : IO, name : String, body : Bytes = Bytes.empty) : Nil
      write_payload(io, Command.named(name, body))
    end

    private def write_payload(io : IO, payload : Bytes) : Nil
      Frame.encode(io, payload, command: true)
      io.flush if io.responds_to?(:flush)
    end

    private def read_command(io : IO, expected_name : String) : Bytes
      payload, _more, is_command = Frame.decode(io)
      raise ProtocolError.new("expected COMMAND frame in PLAIN handshake") unless is_command

      name, body = Command.parse(payload)
      if name == "ERROR"
        raise HandshakeFailed.new(Command.parse_error(body))
      end
      raise ProtocolError.new("expected #{expected_name}, got #{name}") unless name == expected_name
      body
    end

    private def encode_hello(username : String, password : String) : Bytes
      username_bytes = username.to_slice
      password_bytes = password.to_slice
      validate_credential!("PLAIN username", username)
      validate_credential!("PLAIN password", password)

      body = Bytes.new(2 + username_bytes.size + password_bytes.size)
      body[0] = username_bytes.size.to_u8
      body[1, username_bytes.size].copy_from(username_bytes) if username_bytes.size > 0
      password_offset = 1 + username_bytes.size
      body[password_offset] = password_bytes.size.to_u8
      body[password_offset + 1, password_bytes.size].copy_from(password_bytes) if password_bytes.size > 0
      body
    end

    private def decode_hello(body : Bytes) : {String, String}
      raise HandshakeFailed.new("PLAIN HELLO body empty") if body.empty?

      username_len = body[0].to_i
      raise HandshakeFailed.new("PLAIN HELLO truncated in username") if body.size < 1 + username_len + 1
      username = String.new(body[1, username_len])

      password_offset = 1 + username_len
      password_len = body[password_offset].to_i
      raise HandshakeFailed.new("PLAIN HELLO truncated in password") if body.size < password_offset + 1 + password_len
      password = String.new(body[password_offset + 1, password_len])

      {username, password}
    end

    private def validate_credential!(name : String, value : String) : Nil
      size = value.to_slice.size
      raise HandshakeFailed.new("#{name} exceeds 255 bytes") if size > 255
    end
  end
end
