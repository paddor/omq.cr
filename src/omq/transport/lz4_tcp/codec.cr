require "flint"

module OMQ
  module Transport
    module Lz4Tcp
      MAX_DICT_SIZE         = 8192
      DEFAULT_DICT_CAPACITY = 2048
      DEFAULT_TRAIN_TRIGGER =  100

      class ProtocolError < OMQ::ProtocolError
      end

      struct AutoDict
        getter capacity : Int32
        getter trigger : Int32

        def initialize(@capacity : Int32 = DEFAULT_DICT_CAPACITY, @trigger : Int32 = DEFAULT_TRAIN_TRIGGER)
          Lz4Tcp.validate_auto_dict_capacity!(@capacity)
          raise ArgumentError.new("auto_dict trigger must be > 0 (got #{@trigger})") if @trigger <= 0
        end
      end

      def self.validate_dict_size!(size : Int32) : Nil
        return if 1 <= size <= MAX_DICT_SIZE

        raise ProtocolError.new("dict shipment size #{size} out of range [1, #{MAX_DICT_SIZE}]")
      end

      def self.validate_auto_dict_capacity!(size : Int32) : Nil
        return if 1 <= size <= MAX_DICT_SIZE

        raise ArgumentError.new("auto_dict capacity #{size} out of range [1, #{MAX_DICT_SIZE}]")
      end

      module Codec
        extend self

        UNCOMPRESSED_SENTINEL = Bytes[0_u8, 0_u8, 0_u8, 0_u8]
        LZ4B_SENTINEL         = Bytes[0x4c_u8, 0x5a_u8, 0x34_u8, 0x42_u8]
        LZ4M_SENTINEL         = Bytes[0x4c_u8, 0x5a_u8, 0x34_u8, 0x4d_u8]
        LZ4D_SENTINEL         = Bytes[0x4c_u8, 0x5a_u8, 0x34_u8, 0x44_u8]

        LZ4M_BLOCK_SIZE = 1_073_741_824

        MIN_COMPRESS_NO_DICT   = 512
        MIN_COMPRESS_WITH_DICT = 128

        MAX_DICT_SIZE = Lz4Tcp::MAX_DICT_SIZE

        PASSTHROUGH_ENVELOPE =  4
        COMPRESSED_ENVELOPE  = 12

        def encode_part(
          plaintext : Bytes,
          *,
          block_codec : Flint::BlockCodec,
          min_size : Int32? = nil,
          block_size : Int32 = LZ4M_BLOCK_SIZE,
        ) : Bytes
          min = min_size || (block_codec.has_dict? ? MIN_COMPRESS_WITH_DICT : MIN_COMPRESS_NO_DICT)
          return encode_passthrough(plaintext) if plaintext.size < min
          return encode_multi_block(plaintext, block_codec, block_size) if plaintext.size > block_size

          compressed = block_codec.compress_raw(plaintext)
          if compressed.size + COMPRESSED_ENVELOPE >= plaintext.size + PASSTHROUGH_ENVELOPE
            encode_passthrough(plaintext)
          else
            encode_compressed(plaintext.size, compressed)
          end
        end

        def decode_part(
          wire : Bytes,
          *,
          block_codec : Flint::BlockCodec,
          max_size : Int64? = nil,
          block_size : Int32 = LZ4M_BLOCK_SIZE,
        ) : Bytes
          raise ProtocolError.new("wire part too short (< 4 bytes)") if wire.size < 4

          sentinel = wire[0, 4]
          case
          when sentinel == UNCOMPRESSED_SENTINEL
            payload = wire[4, wire.size - 4]
            check_size!(payload.size.to_i64, max_size)
            payload.dup
          when sentinel == LZ4B_SENTINEL
            decode_single_block(wire, block_codec, max_size, block_size)
          when sentinel == LZ4M_SENTINEL
            decode_multi_block(wire, block_codec, max_size, block_size)
          when sentinel == LZ4D_SENTINEL
            raise ProtocolError.new("LZ4D dictionary shipment seen at decode_part")
          else
            raise ProtocolError.new("unknown lz4+tcp sentinel")
          end
        end

        def dict_shipment?(wire : Bytes) : Bool
          wire.size >= 4 && wire[0, 4] == LZ4D_SENTINEL
        end

        def encode_dict_shipment(dict : Bytes) : Bytes
          Lz4Tcp.validate_dict_size!(dict.size)
          output = Bytes.new(4 + dict.size)
          output[0, 4].copy_from(LZ4D_SENTINEL)
          output[4, dict.size].copy_from(dict)
          output
        end

        def decode_dict_shipment(wire : Bytes) : Bytes
          raise ProtocolError.new("dict shipment too short (< 4 bytes)") if wire.size < 4
          unless wire[0, 4] == LZ4D_SENTINEL
            raise ProtocolError.new("not a dict shipment")
          end

          dict = wire[4, wire.size - 4]
          Lz4Tcp.validate_dict_size!(dict.size)
          dict.dup
        end

        private def decode_single_block(
          wire : Bytes,
          block_codec : Flint::BlockCodec,
          max_size : Int64?,
          block_size : Int32,
        ) : Bytes
          raise ProtocolError.new("LZ4B part too short (< 12 bytes)") if wire.size < COMPRESSED_ENVELOPE

          decoded_size = read_u64_le(wire[4, 8])
          if decoded_size > block_size.to_u64
            raise ProtocolError.new("LZ4B decompressed_size #{decoded_size} exceeds block size limit #{block_size}")
          end
          check_size!(u64_to_i64(decoded_size), max_size)

          block = wire[12, wire.size - 12]
          block_codec.decompress_raw_exact(block, decoded_size.to_i32)
        rescue ex : Flint::Error
          raise ProtocolError.new("LZ4B decode failed: #{ex.message}")
        end

        private def encode_multi_block(
          plaintext : Bytes,
          block_codec : Flint::BlockCodec,
          block_size : Int32,
        ) : Bytes
          io = IO::Memory.new
          io.write(LZ4M_SENTINEL)
          write_u64_le(io, plaintext.size.to_u64)

          offset = 0
          while offset < plaintext.size
            chunk_size = {block_size, plaintext.size - offset}.min
            compressed = block_codec.compress_raw(plaintext[offset, chunk_size])
            write_u32_le(io, compressed.size.to_u32)
            io.write(compressed)
            offset += chunk_size
          end

          io.to_slice
        end

        private def decode_multi_block(
          wire : Bytes,
          block_codec : Flint::BlockCodec,
          max_size : Int64?,
          block_size : Int32,
        ) : Bytes
          raise ProtocolError.new("LZ4M part too short (< 12 bytes)") if wire.size < COMPRESSED_ENVELOPE

          decoded_size = read_u64_le(wire[4, 8])
          check_size!(u64_to_i64(decoded_size), max_size)
          output = Bytes.new(u64_to_i32(decoded_size))

          offset = 12
          remaining = decoded_size
          dst = 0

          while remaining > 0
            if offset + 4 > wire.size
              raise ProtocolError.new("LZ4M truncated: missing block length")
            end

            compressed_len = read_u32_le(wire[offset, 4])
            offset += 4

            if offset + compressed_len > wire.size
              raise ProtocolError.new("LZ4M truncated: block extends past wire end")
            end

            block_decoded_size = {block_size.to_u64, remaining}.min
            decoded = block_codec.decompress_raw_exact(wire[offset, compressed_len], block_decoded_size.to_i32)
            output[dst, decoded.size].copy_from(decoded)

            offset += compressed_len
            dst += decoded.size
            remaining -= block_decoded_size
          end

          if offset != wire.size
            raise ProtocolError.new("LZ4M has #{wire.size - offset} leftover bytes")
          end

          output
        rescue ex : Flint::Error
          raise ProtocolError.new("LZ4M block decode failed: #{ex.message}")
        end

        private def encode_passthrough(plaintext : Bytes) : Bytes
          output = Bytes.new(PASSTHROUGH_ENVELOPE + plaintext.size)
          output[0, 4].copy_from(UNCOMPRESSED_SENTINEL)
          output[4, plaintext.size].copy_from(plaintext)
          output
        end

        private def encode_compressed(decompressed_size : Int32, compressed : Bytes) : Bytes
          output = Bytes.new(COMPRESSED_ENVELOPE + compressed.size)
          output[0, 4].copy_from(LZ4B_SENTINEL)
          write_u64_le(output[4, 8], decompressed_size.to_u64)
          output[12, compressed.size].copy_from(compressed)
          output
        end

        private def check_size!(declared_size : Int64, max_size : Int64?) : Nil
          return unless max = max_size
          return if declared_size <= max

          raise ProtocolError.new("part size #{declared_size} exceeds max_size #{max}")
        end

        private def u64_to_i64(size : UInt64) : Int64
          raise ProtocolError.new("declared size exceeds Int64::MAX") if size > Int64::MAX

          size.to_i64
        end

        private def u64_to_i32(size : UInt64) : Int32
          raise ProtocolError.new("declared size exceeds Int32::MAX") if size > Int32::MAX

          size.to_i32
        end

        private def read_u64_le(bytes : Bytes) : UInt64
          value = 0_u64
          8.times { |i| value |= bytes[i].to_u64 << (i * 8) }
          value
        end

        private def read_u32_le(bytes : Bytes) : Int32
          value = 0_u32
          4.times { |i| value |= bytes[i].to_u32 << (i * 8) }
          raise ProtocolError.new("block length exceeds Int32::MAX") if value > Int32::MAX

          value.to_i32
        end

        private def write_u64_le(bytes : Bytes, value : UInt64) : Nil
          8.times { |i| bytes[i] = ((value >> (i * 8)) & 0xff).to_u8 }
        end

        private def write_u64_le(io : IO, value : UInt64) : Nil
          buf = Bytes.new(8)
          write_u64_le(buf, value)
          io.write(buf)
        end

        private def write_u32_le(io : IO, value : UInt32) : Nil
          4.times { |i| io.write_byte(((value >> (i * 8)) & 0xff).to_u8) }
        end
      end
    end
  end
end
