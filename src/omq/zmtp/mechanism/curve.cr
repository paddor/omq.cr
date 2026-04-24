require "natron"

module OMQ::ZMTP
  # CurveZMQ (RFC 26): Curve25519 key exchange + XSalsa20-Poly1305
  # authenticated encryption. Backed by `natron` (libsodium).
  #
  # Construct via the class-level factories; set via `socket.mechanism = ...`
  # before bind/connect:
  #
  #     server_sk = Natron::PrivateKey.generate
  #     server_pk = server_sk.public_key
  #
  #     rep = OMQ::REP.new
  #     rep.mechanism = OMQ::ZMTP::Mechanism::Curve.server(
  #       public_key: server_pk.bytes, secret_key: server_sk.bytes)
  #     rep.bind("tcp://127.0.0.1:5555")
  #
  #     client_sk = Natron::PrivateKey.generate
  #     req = OMQ::REQ.new
  #     req.mechanism = OMQ::ZMTP::Mechanism::Curve.client(
  #       server_key: server_pk.bytes,
  #       public_key: client_sk.public_key.bytes,
  #       secret_key: client_sk.bytes)
  #     req.connect("tcp://127.0.0.1:5555")
  class Mechanism::Curve < Mechanism
    NAME = "CURVE"

    # Nonce prefixes (16 bytes each) per RFC 26.
    NONCE_PREFIX_HELLO     = "CurveZMQHELLO---".to_slice
    NONCE_PREFIX_WELCOME   = "WELCOME-".to_slice
    NONCE_PREFIX_INITIATE  = "CurveZMQINITIATE".to_slice
    NONCE_PREFIX_READY     = "CurveZMQREADY---".to_slice
    NONCE_PREFIX_MESSAGE_C = "CurveZMQMESSAGEC".to_slice
    NONCE_PREFIX_MESSAGE_S = "CurveZMQMESSAGES".to_slice
    NONCE_PREFIX_VOUCH     = "VOUCH---".to_slice
    NONCE_PREFIX_COOKIE    = "COOKIE--".to_slice

    BOX_OVERHEAD = 16
    MAX_NONCE    = UInt64::MAX


    def self.server(*, public_key : Bytes, secret_key : Bytes, authenticator : Proc(Bytes, Bool)? = nil) : Curve
      new(public_key: public_key, secret_key: secret_key, server_key: nil, as_server: true, authenticator: authenticator)
    end


    def self.client(*, server_key : Bytes, public_key : Bytes? = nil, secret_key : Bytes? = nil) : Curve
      new(public_key: public_key, secret_key: secret_key, server_key: server_key, as_server: false)
    end


    @permanent_public : Natron::PublicKey
    @permanent_secret : Natron::PrivateKey
    @server_public : Natron::PublicKey?
    @cookie_key : Bytes?
    @session_box : Natron::Box?
    @send_prefix : Bytes
    @recv_prefix : Bytes
    @send_nonce : UInt64 = 0_u64
    @recv_nonce : UInt64 = 0_u64


    def initialize(*, public_key : Bytes?, secret_key : Bytes?, server_key : Bytes?, @as_server : Bool, @authenticator : Proc(Bytes, Bool)? = nil)
      if @as_server
        raise ArgumentError.new("public_key required") unless public_key
        raise ArgumentError.new("secret_key required") unless secret_key
        @permanent_public = Natron::PublicKey.new(public_key)
        @permanent_secret = Natron::PrivateKey.new(secret_key)
        @server_public = nil
        @cookie_key = Natron::Random.random_bytes(32)
      else
        raise ArgumentError.new("server_key required") unless server_key
        @server_public = Natron::PublicKey.new(server_key)
        if public_key && secret_key
          @permanent_public = Natron::PublicKey.new(public_key)
          @permanent_secret = Natron::PrivateKey.new(secret_key)
        else
          @permanent_secret = Natron::PrivateKey.generate
          @permanent_public = @permanent_secret.public_key
        end
        @cookie_key = nil
      end
      @send_prefix = @as_server ? NONCE_PREFIX_MESSAGE_S : NONCE_PREFIX_MESSAGE_C
      @recv_prefix = @as_server ? NONCE_PREFIX_MESSAGE_C : NONCE_PREFIX_MESSAGE_S
    end


    def name : String
      NAME
    end


    def encrypted? : Bool
      true
    end


    def handshake(io : IO, *, local_socket_type : String, local_identity : Bytes, as_server : Bool) : Hash(String, Bytes)
      if @as_server
        server_handshake(io, local_socket_type, local_identity)
      else
        client_handshake(io, local_socket_type, local_identity)
      end
    end


    def encrypt(payload : Bytes, *, more : Bool, command : Bool) : Bytes
      flags = 0_u8
      flags |= FLAG_MORE if more
      flags |= FLAG_COMMAND if command
      plaintext = Bytes.new(1 + payload.size)
      plaintext[0] = flags
      payload.copy_to(plaintext + 1) if payload.size > 0

      nonce, short_nonce = next_send_nonce
      ciphertext = session_box.encrypt(nonce, plaintext)

      body = Bytes.new(1 + "MESSAGE".bytesize + short_nonce.size + ciphertext.size)
      io = IO::Memory.new(body)
      io.write_byte(7_u8)
      io.write("MESSAGE".to_slice)
      io.write(short_nonce)
      io.write(ciphertext)
      body
    end


    def decrypt(body : Bytes) : {Bytes, Bool, Bool}
      io = IO::Memory.new(body)
      name_len = (io.read_byte || raise ProtocolError.new("empty CURVE frame")).to_i
      raise ProtocolError.new("CURVE frame too short") if body.size < 1 + name_len + 8 + BOX_OVERHEAD
      name_bytes = Bytes.new(name_len)
      io.read_fully(name_bytes)
      raise ProtocolError.new("expected MESSAGE, got #{String.new(name_bytes)}") unless String.new(name_bytes) == "MESSAGE"

      short_nonce = Bytes.new(8)
      io.read_fully(short_nonce)
      ciphertext = Bytes.new(body.size - io.pos)
      io.read_fully(ciphertext)

      nonce_value = IO::ByteFormat::NetworkEndian.decode(UInt64, short_nonce)
      raise ProtocolError.new("MESSAGE nonce not strictly increasing") unless nonce_value > @recv_nonce
      @recv_nonce = nonce_value

      full_nonce = Bytes.new(24)
      @recv_prefix.copy_to(full_nonce)
      short_nonce.copy_to(full_nonce + 16)
      plaintext = session_box.decrypt(full_nonce, ciphertext)

      flags = plaintext[0]
      inner = plaintext.size > 1 ? plaintext[1, plaintext.size - 1] : Bytes.empty
      more = (flags & FLAG_MORE) != 0
      command = (flags & FLAG_COMMAND) != 0
      {inner, more, command}
    end


    private def session_box : Natron::Box
      @session_box || raise ProtocolError.new("CURVE session not established")
    end


    private def next_send_nonce : {Bytes, Bytes}
      @send_nonce += 1
      raise ProtocolError.new("nonce counter exhausted") if @send_nonce == 0_u64
      short = Bytes.new(8)
      IO::ByteFormat::NetworkEndian.encode(@send_nonce, short)
      full = Bytes.new(24)
      @send_prefix.copy_to(full)
      short.copy_to(full + 16)
      {full, short}
    end


    private def write_command(io : IO, body : Bytes) : Nil
      Frame.encode(io, body, command: true)
      io.flush if io.responds_to?(:flush)
    end


    private def read_command(io : IO, expected_name : String) : Bytes
      payload, _more, is_command = Frame.decode(io)
      raise ProtocolError.new("expected command frame") unless is_command
      name, rest = Command.parse(payload)
      raise ProtocolError.new("expected #{expected_name}, got #{name}") unless name == expected_name
      rest
    end


    private def build_command(name : String, data : Bytes) : Bytes
      name_bytes = name.to_slice
      body = Bytes.new(1 + name_bytes.size + data.size)
      body[0] = name_bytes.size.to_u8
      name_bytes.copy_to(body + 1)
      data.copy_to(body + 1 + name_bytes.size) if data.size > 0
      body
    end


    private def join_bytes(parts : Array(Bytes)) : Bytes
      total = parts.sum(&.size)
      buf = Bytes.new(total)
      offset = 0
      parts.each do |p|
        p.copy_to(buf + offset) if p.size > 0
        offset += p.size
      end
      buf
    end


    private def nonce_with(prefix : Bytes, short : Bytes) : Bytes
      raise ProtocolError.new("nonce suffix wrong size") unless short.size == 8 || short.size == 16
      buf = Bytes.new(prefix.size + short.size)
      prefix.copy_to(buf)
      short.copy_to(buf + prefix.size)
      buf
    end


    # ------------------------------------------------------------------
    # Client-side handshake
    # ------------------------------------------------------------------

    private def client_handshake(io : IO, local_socket_type : String, local_identity : Bytes) : Hash(String, Bytes)
      server_pub = @server_public || raise "client without server_key"
      cn_secret = Natron::PrivateKey.generate
      cn_public = cn_secret.public_key

      # --- HELLO ---
      short_nonce = Bytes.new(8)
      IO::ByteFormat::NetworkEndian.encode(1_u64, short_nonce)
      hello_nonce = nonce_with(NONCE_PREFIX_HELLO, short_nonce)
      signature = Natron::Box.new(server_pub, cn_secret).encrypt(hello_nonce, Bytes.new(64))

      hello_data = join_bytes([
        Bytes.new(1) { |_| 0x01_u8 },  # will overwrite below
        Bytes.new(1) { |_| 0x00_u8 },  # filler minor version placeholder
      ])
      # Actual HELLO data layout: version(2) + filler(72) + cn_public(32) +
      # short_nonce(8) + signature(80) = 194.
      hello_data = Bytes.new(194)
      hello_data[0] = 0x01_u8
      hello_data[1] = 0x00_u8
      cn_public.bytes.copy_to(hello_data + 74)
      short_nonce.copy_to(hello_data + 106)
      signature.copy_to(hello_data + 114)

      write_command(io, build_command("HELLO", hello_data))

      # --- Read WELCOME ---
      wdata = read_command(io, "WELCOME")
      raise ProtocolError.new("WELCOME wrong size: #{wdata.size}") unless wdata.size == 16 + 144

      w_short_nonce = wdata[0, 16]
      w_ciphertext = wdata[16, 144]
      w_nonce = nonce_with(NONCE_PREFIX_WELCOME, w_short_nonce)
      w_plaintext = Natron::Box.new(server_pub, cn_secret).decrypt(w_nonce, w_ciphertext)

      sn_public = Natron::PublicKey.new(w_plaintext[0, 32])
      cookie = w_plaintext[32, 96]

      session = Natron::Box.new(sn_public, cn_secret)

      # --- INITIATE ---
      vouch_suffix = Natron::Random.random_bytes(16)
      vouch_nonce = nonce_with(NONCE_PREFIX_VOUCH, vouch_suffix)
      vouch_plain = join_bytes([cn_public.bytes, server_pub.bytes])
      vouch = Natron::Box.new(sn_public, @permanent_secret).encrypt(vouch_nonce, vouch_plain)

      props_io = IO::Memory.new
      write_property(props_io, "Socket-Type", local_socket_type.to_slice)
      write_property(props_io, "Identity", local_identity)
      metadata_bytes = props_io.to_slice

      init_plain = join_bytes([
        @permanent_public.bytes,
        vouch_suffix,
        vouch,
        metadata_bytes,
      ])

      init_short = Bytes.new(8)
      IO::ByteFormat::NetworkEndian.encode(1_u64, init_short)
      init_nonce = nonce_with(NONCE_PREFIX_INITIATE, init_short)
      init_ct = session.encrypt(init_nonce, init_plain)

      init_data = join_bytes([cookie, init_short, init_ct])
      write_command(io, build_command("INITIATE", init_data))

      # --- Read READY ---
      rdata = read_command(io, "READY")
      raise ProtocolError.new("READY too short") if rdata.size < 8 + BOX_OVERHEAD
      r_short = rdata[0, 8]
      r_ct = rdata[8, rdata.size - 8]
      r_nonce = nonce_with(NONCE_PREFIX_READY, r_short)
      r_plain = session.decrypt(r_nonce, r_ct)
      props = Command.parse_properties(r_plain)

      @session_box = session
      @send_nonce = 1_u64
      @recv_nonce = 0_u64
      props
    end


    # ------------------------------------------------------------------
    # Server-side handshake
    # ------------------------------------------------------------------

    private def server_handshake(io : IO, local_socket_type : String, local_identity : Bytes) : Hash(String, Bytes)
      cookie_key = @cookie_key || raise "server without cookie_key"

      # --- Read HELLO ---
      hdata = read_command(io, "HELLO")
      raise ProtocolError.new("HELLO wrong size: #{hdata.size}") unless hdata.size == 194

      cn_public = Natron::PublicKey.new(hdata[74, 32])
      h_short = hdata[106, 8]
      h_sig = hdata[114, 80]
      h_nonce = nonce_with(NONCE_PREFIX_HELLO, h_short)
      plaintext = Natron::Box.new(cn_public, @permanent_secret).decrypt(h_nonce, h_sig)
      raise ProtocolError.new("HELLO signature content invalid") unless Natron::Util.verify64(plaintext, Bytes.new(64))

      # --- WELCOME ---
      sn_secret = Natron::PrivateKey.generate
      sn_public = sn_secret.public_key

      cookie_suffix = Natron::Random.random_bytes(16)
      cookie_nonce = nonce_with(NONCE_PREFIX_COOKIE, cookie_suffix)
      cookie_plain = join_bytes([cn_public.bytes, sn_secret.bytes])
      cookie_ct = Natron::SecretBox.new(cookie_key).encrypt(cookie_nonce, cookie_plain)
      cookie = join_bytes([cookie_suffix, cookie_ct])

      w_plain = join_bytes([sn_public.bytes, cookie])
      w_short = Natron::Random.random_bytes(16)
      w_nonce = nonce_with(NONCE_PREFIX_WELCOME, w_short)
      w_ct = Natron::Box.new(cn_public, @permanent_secret).encrypt(w_nonce, w_plain)

      write_command(io, build_command("WELCOME", join_bytes([w_short, w_ct])))

      # --- Read INITIATE ---
      idata = read_command(io, "INITIATE")
      raise ProtocolError.new("INITIATE too short") if idata.size < 96 + 8 + BOX_OVERHEAD

      recv_cookie = idata[0, 96]
      i_short = idata[96, 8]
      i_ct = idata[104, idata.size - 104]

      cookie_short = recv_cookie[0, 16]
      cookie_ciphertext = recv_cookie[16, 80]
      cookie_decrypt_nonce = nonce_with(NONCE_PREFIX_COOKIE, cookie_short)
      cookie_contents = Natron::SecretBox.new(cookie_key).decrypt(cookie_decrypt_nonce, cookie_ciphertext)

      cn_public = Natron::PublicKey.new(cookie_contents[0, 32])
      sn_secret = Natron::PrivateKey.new(cookie_contents[32, 32])

      session = Natron::Box.new(cn_public, sn_secret)
      i_nonce = nonce_with(NONCE_PREFIX_INITIATE, i_short)
      i_plain = session.decrypt(i_nonce, i_ct)

      raise ProtocolError.new("INITIATE plaintext too short") if i_plain.size < 32 + 16 + 80

      client_permanent = Natron::PublicKey.new(i_plain[0, 32])
      vouch_suffix = i_plain[32, 16]
      vouch_ct = i_plain[48, 80]
      metadata_bytes = i_plain.size > 128 ? i_plain[128, i_plain.size - 128] : Bytes.empty

      vouch_nonce = nonce_with(NONCE_PREFIX_VOUCH, vouch_suffix)
      vouch_plain = Natron::Box.new(client_permanent, sn_secret).decrypt(vouch_nonce, vouch_ct)
      raise ProtocolError.new("vouch wrong size") unless vouch_plain.size == 64
      raise ProtocolError.new("vouch client transient key mismatch") unless Natron::Util.verify32(vouch_plain[0, 32], cn_public.bytes)
      raise ProtocolError.new("vouch server key mismatch") unless Natron::Util.verify32(vouch_plain[32, 32], @permanent_public.bytes)

      if auth = @authenticator
        raise ProtocolError.new("client key not authorized") unless auth.call(client_permanent.bytes)
      end

      # --- READY ---
      props_io = IO::Memory.new
      write_property(props_io, "Socket-Type", local_socket_type.to_slice)
      write_property(props_io, "Identity", local_identity)
      ready_metadata = props_io.to_slice

      r_short = Bytes.new(8)
      IO::ByteFormat::NetworkEndian.encode(1_u64, r_short)
      r_nonce = nonce_with(NONCE_PREFIX_READY, r_short)
      r_ct = session.encrypt(r_nonce, ready_metadata)

      write_command(io, build_command("READY", join_bytes([r_short, r_ct])))

      peer_props = Command.parse_properties(metadata_bytes)
      @session_box = session
      @send_nonce = 1_u64
      @recv_nonce = 0_u64
      peer_props
    end


    private def write_property(io : IO::Memory, name : String, value : Bytes) : Nil
      name_bytes = name.to_slice
      io.write_byte(name_bytes.size.to_u8)
      io.write(name_bytes)
      io.write_bytes(value.size.to_u32, IO::ByteFormat::NetworkEndian)
      io.write(value) if value.size > 0
    end
  end
end
