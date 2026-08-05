require "natron"

module OMQ::Curve
  Z85_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#".to_slice
  KEY_SIZE     = 32
  Z85_KEY_SIZE = 40

  # Encode bytes with the RFC 32 Z85 alphabet.
  def self.z85_encode(data : Bytes) : String
    unless data.size % 4 == 0
      raise ArgumentError.new("Z85 input must be a multiple of 4 bytes, got #{data.size}")
    end

    encoded = Bytes.new(data.size // 4 * 5)
    input_offset = 0
    output_offset = 0

    while input_offset < data.size
      value = (data[input_offset].to_u64 << 24) |
              (data[input_offset + 1].to_u64 << 16) |
              (data[input_offset + 2].to_u64 << 8) |
              data[input_offset + 3].to_u64

      encoded[output_offset] = Z85_ALPHABET[((value // 52_200_625_u64) % 85).to_i]
      encoded[output_offset + 1] = Z85_ALPHABET[((value // 614_125_u64) % 85).to_i]
      encoded[output_offset + 2] = Z85_ALPHABET[((value // 7_225_u64) % 85).to_i]
      encoded[output_offset + 3] = Z85_ALPHABET[((value // 85_u64) % 85).to_i]
      encoded[output_offset + 4] = Z85_ALPHABET[(value % 85).to_i]

      input_offset += 4
      output_offset += 5
    end

    String.new(encoded)
  end

  # Decode an RFC 32 Z85 string.
  def self.z85_decode(text : String) : Bytes
    data = text.to_slice
    unless data.size % 5 == 0
      raise ArgumentError.new("Z85 input must be a multiple of 5 chars, got #{data.size}")
    end

    decoded = Bytes.new(data.size // 5 * 4)
    input_offset = 0
    output_offset = 0

    while input_offset < data.size
      value = 0_u64
      5.times do |i|
        digit = z85_digit(data[input_offset + i])
        if digit < 0
          raise ArgumentError.new("Z85 invalid character: #{data[input_offset + i].chr.inspect}")
        end
        value = value * 85_u64 + digit.to_u64
      end

      if value > UInt32::MAX.to_u64
        raise ArgumentError.new("Z85 chunk overflowed u32")
      end

      decoded[output_offset] = ((value >> 24) & 0xff).to_u8
      decoded[output_offset + 1] = ((value >> 16) & 0xff).to_u8
      decoded[output_offset + 2] = ((value >> 8) & 0xff).to_u8
      decoded[output_offset + 3] = (value & 0xff).to_u8

      input_offset += 5
      output_offset += 4
    end

    decoded
  end

  private def self.z85_digit(byte : UInt8) : Int32
    Z85_ALPHABET.each_with_index do |candidate, index|
      return index if candidate == byte
    end
    -1
  end

  struct PublicKey
    @bytes : Bytes

    def initialize(bytes : Bytes)
      unless bytes.size == KEY_SIZE
        raise ArgumentError.new("CURVE public key must be #{KEY_SIZE} bytes, got #{bytes.size}")
      end
      @bytes = bytes.dup
    end

    def self.from_z85(text : String) : self
      raw = Curve.z85_decode(text)
      new(raw)
    end

    def bytes : Bytes
      @bytes.dup
    end

    def to_z85 : String
      Curve.z85_encode(@bytes)
    end

    def inspect(io : IO) : Nil
      io << "OMQ::Curve::PublicKey(" << to_z85 << ")"
    end
  end

  struct SecretKey
    @bytes : Bytes

    def initialize(bytes : Bytes)
      unless bytes.size == KEY_SIZE
        raise ArgumentError.new("CURVE secret key must be #{KEY_SIZE} bytes, got #{bytes.size}")
      end
      @bytes = bytes.dup
    end

    def self.from_z85(text : String) : self
      raw = Curve.z85_decode(text)
      new(raw)
    end

    def bytes : Bytes
      @bytes.dup
    end

    def to_z85 : String
      Curve.z85_encode(@bytes)
    end

    def derive_public : PublicKey
      PublicKey.new(Natron::PrivateKey.new(@bytes).public_key.bytes)
    end

    def inspect(io : IO) : Nil
      io << "OMQ::Curve::SecretKey(<redacted>)"
    end
  end

  struct KeyPair
    getter public_key : PublicKey
    getter secret_key : SecretKey

    def initialize(@public_key : PublicKey, @secret_key : SecretKey)
    end

    def self.generate : self
      secret = Natron::PrivateKey.generate
      new(PublicKey.new(secret.public_key.bytes), SecretKey.new(secret.bytes))
    end

    def public_bytes : Bytes
      @public_key.bytes
    end

    def secret_bytes : Bytes
      @secret_key.bytes
    end

    def public_z85 : String
      @public_key.to_z85
    end

    def secret_z85 : String
      @secret_key.to_z85
    end

    def inspect(io : IO) : Nil
      io << "OMQ::Curve::KeyPair(public_key: "
      @public_key.inspect(io)
      io << ", secret_key: <redacted>)"
    end
  end

  alias Keypair = KeyPair

  def self.keypair : KeyPair
    KeyPair.generate
  end
end
