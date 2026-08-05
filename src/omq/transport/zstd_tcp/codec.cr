require "zinc"

module OMQ
  module Transport
    module ZstdTcp
      class ProtocolError < OMQ::ProtocolError
      end

      module Codec
        extend self

        UNCOMPRESSED_SENTINEL = Bytes[0_u8, 0_u8, 0_u8, 0_u8]
        ZSTD_MAGIC            = Bytes[0x28_u8, 0xb5_u8, 0x2f_u8, 0xfd_u8]
        ZDICT_MAGIC           = Bytes[0x37_u8, 0xa4_u8, 0x30_u8, 0xec_u8]

        DEFAULT_LEVEL = -3

        MIN_COMPRESS_NO_DICT   = 512
        MIN_COMPRESS_WITH_DICT =  64

        MAX_DICT_SIZE        = 8 * 1024
        DICT_CAPACITY        = 2 * 1024
        TRAIN_MAX_SAMPLES    = 1000
        TRAIN_MAX_BYTES      = 100 * 1024
        TRAIN_MAX_SAMPLE_LEN = 2048

        PASSTHROUGH_ENVELOPE = 4

        USER_DICT_ID_MIN =        32_768
        USER_DICT_ID_MAX = 2_147_483_647

        def encode_part(
          plaintext : Bytes,
          *,
          frame_codec : Zinc::FrameCodec,
          min_size : Int32? = nil,
        ) : Bytes
          min = min_size || (frame_codec.has_dict? ? MIN_COMPRESS_WITH_DICT : MIN_COMPRESS_NO_DICT)
          return encode_passthrough(plaintext) if plaintext.size < min

          compressed = frame_codec.compress(plaintext)
          if compressed.size >= plaintext.size - PASSTHROUGH_ENVELOPE
            encode_passthrough(plaintext)
          else
            compressed
          end
        rescue ex : Zinc::Error
          raise ProtocolError.new("Zstd encode failed: #{ex.message}")
        end

        def decode_part(
          wire : Bytes,
          *,
          frame_codec : Zinc::FrameCodec,
          no_dict_frame_codec : Zinc::FrameCodec? = nil,
          max_size : Int64? = nil,
        ) : Bytes
          raise ProtocolError.new("wire part too short (< 4 bytes)") if wire.size < 4

          sentinel = wire[0, 4]
          case
          when sentinel == UNCOMPRESSED_SENTINEL
            plaintext = wire[4, wire.size - 4]
            check_size!(plaintext.size.to_i64, max_size)
            plaintext.dup
          when sentinel == ZSTD_MAGIC
            decode_zstd_frame(wire, frame_codec, no_dict_frame_codec || frame_codec, max_size)
          when sentinel == ZDICT_MAGIC
            raise ProtocolError.new("ZDICT dictionary shipment seen at decode_part")
          else
            raise ProtocolError.new("unknown zstd+tcp sentinel")
          end
        end

        def parse_frame_content_size(wire : Bytes) : UInt64?
          Zinc::FrameCodec.get_frame_content_size(wire)
        rescue ex
          raise ProtocolError.new("Zstd frame header invalid: #{ex.message}")
        end

        def frame_has_dict_id?(wire : Bytes) : Bool
          wire.size >= 5 && (wire[4] & 0x03) != 0
        end

        def dict_shipment?(wire : Bytes) : Bool
          wire.size >= 4 && wire[0, 4] == ZDICT_MAGIC
        end

        def encode_dict_shipment(dict : Bytes) : Bytes
          validate_zdict!(dict)
          dict.dup
        end

        def decode_dict_shipment(wire : Bytes) : Bytes
          validate_zdict!(wire)
          wire.dup
        end

        def validate_zdict!(dict : Bytes) : Nil
          validate_dict_size!(dict.size)
          unless dict.size >= 4 && dict[0, 4] == ZDICT_MAGIC
            raise ProtocolError.new("supplied dict is not ZDICT-format")
          end
        end

        def validate_dict_size!(size : Int32) : Nil
          return if 1 <= size <= MAX_DICT_SIZE

          raise ProtocolError.new("dict shipment size #{size} out of range [1, #{MAX_DICT_SIZE}]")
        end

        private def decode_zstd_frame(
          wire : Bytes,
          frame_codec : Zinc::FrameCodec,
          no_dict_frame_codec : Zinc::FrameCodec,
          max_size : Int64?,
        ) : Bytes
          fcs = parse_frame_content_size(wire)
          raise ProtocolError.new("Zstd frame missing Frame_Content_Size") unless fcs
          raise ProtocolError.new("declared FCS #{fcs} exceeds Int32::MAX") if fcs > Int32::MAX
          check_size!(fcs.to_i64, max_size)

          codec = frame_has_dict_id?(wire) ? frame_codec : no_dict_frame_codec
          codec.decompress(wire, max_output_size: fcs.to_i32)
        rescue ex : Zinc::DecompressError
          raise ProtocolError.new("Zstd decode failed: #{ex.message}")
        end

        private def encode_passthrough(plaintext : Bytes) : Bytes
          output = Bytes.new(PASSTHROUGH_ENVELOPE + plaintext.size)
          output[0, 4].copy_from(UNCOMPRESSED_SENTINEL)
          output[4, plaintext.size].copy_from(plaintext)
          output
        end

        private def check_size!(declared_size : Int64, max_size : Int64?) : Nil
          return unless max = max_size
          return if declared_size <= max

          raise ProtocolError.new("declared size #{declared_size} exceeds max_size #{max}")
        end
      end

      struct AutoDict
        getter capacity : Int32
        getter max_samples : Int32
        getter max_bytes : Int32
        getter max_sample_size : Int32

        def initialize(
          @capacity : Int32 = Codec::DICT_CAPACITY,
          @max_samples : Int32 = Codec::TRAIN_MAX_SAMPLES,
          @max_bytes : Int32 = Codec::TRAIN_MAX_BYTES,
          @max_sample_size : Int32 = Codec::TRAIN_MAX_SAMPLE_LEN,
        )
          validate_positive!(@capacity, "auto_dict capacity")
          validate_positive!(@max_samples, "auto_dict max_samples")
          validate_positive!(@max_bytes, "auto_dict max_bytes")
          validate_positive!(@max_sample_size, "auto_dict max_sample_size")
          if @capacity > Codec::MAX_DICT_SIZE
            raise ArgumentError.new("auto_dict capacity #{@capacity} out of range [1, #{Codec::MAX_DICT_SIZE}]")
          end
        end

        private def validate_positive!(value : Int32, name : String) : Nil
          raise ArgumentError.new("#{name} must be > 0 (got #{value})") if value <= 0
        end
      end

      class SendState
        getter level : Int32
        getter send_dict_bytes : Bytes? = nil

        @send_codec : Zinc::FrameCodec
        @auto_dict : AutoDict?
        @train_samples : Array(Bytes)?
        @train_bytes : Int32
        @mutex = Mutex.new
        @cached_parts : Message?
        @cached_encoded : Message?

        def initialize(
          @level : Int32 = Codec::DEFAULT_LEVEL,
          *,
          dict : Bytes? = nil,
          auto_dict : AutoDict? = nil,
        )
          raise ArgumentError.new("cannot combine auto_dict: and dict:") if dict && auto_dict

          @send_codec = Zinc::FrameCodec.new(level: @level)
          @auto_dict = auto_dict
          @train_samples = auto_dict ? [] of Bytes : nil
          @train_bytes = 0
          install_send_dict(dict) if dict
        end

        def encode_parts(parts : Message) : Message
          @mutex.synchronize do
            if cached_parts = @cached_parts
              if cached_parts.same?(parts)
                return @cached_encoded.not_nil!
              end
            end

            parts.each { |part| maybe_train!(part) }
            encoded = parts.map { |part| Codec.encode_part(part, frame_codec: @send_codec) }
            @cached_parts = parts
            @cached_encoded = encoded
            encoded
          end
        end

        private def maybe_train!(part : Bytes) : Nil
          auto = @auto_dict
          samples = @train_samples
          return unless auto && samples
          return if part.size > auto.max_sample_size

          samples << part.dup
          @train_bytes += part.size
          return unless samples.size >= auto.max_samples || @train_bytes >= auto.max_bytes

          finish_training!(auto, samples)
        end

        private def finish_training!(auto : AutoDict, samples : Array(Bytes)) : Nil
          @auto_dict = nil
          @train_samples = nil
          trainer = Zinc::DictTrainer.new(auto.capacity)
          samples.each { |sample| trainer.add_sample(sample) }
          dict = trainer.train
          return if dict.empty?

          install_send_dict(patch_auto_dict_id(dict))
        rescue ex : Zinc::Error
          @auto_dict = nil
          @train_samples = nil
        end

        private def install_send_dict(dict : Bytes) : Nil
          Codec.validate_zdict!(dict)
          @send_dict_bytes = dict.dup
          @send_codec = Zinc::FrameCodec.new(dict: dict, level: @level)
          @cached_parts = nil
          @cached_encoded = nil
        rescue ex : Zinc::Error
          raise ProtocolError.new("ZDICT load failed: #{ex.message}")
        end

        private def patch_auto_dict_id(dict : Bytes) : Bytes
          patched = dict.dup
          id = Random.rand(Codec::USER_DICT_ID_MIN..Codec::USER_DICT_ID_MAX)
          IO::ByteFormat::LittleEndian.encode(id.to_u32, patched[4, 4])
          patched
        end
      end
    end
  end
end
