module OMQ
  DEBUG = !ENV["OMQ_DEBUG"]?.nil?

  alias Message = Array(Bytes)

  module ZMTP
    SIGNATURE = Bytes[0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0x7F]

    MAJOR_VERSION = 3_u8
    MINOR_VERSION = 1_u8

    MIN_ACCEPTED_MAJOR = 3_u8

    GREETING_SIZE = 64

    FLAG_MORE    = 0x01_u8
    FLAG_LONG    = 0x02_u8
    FLAG_COMMAND = 0x04_u8
  end
end
