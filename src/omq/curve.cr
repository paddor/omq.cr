require "./../omq"
require "./curve/keys"
require "./zmtp/mechanism/curve"

# CurveZMQ (RFC 26) support. Require this file to enable CURVE encryption:
#
#     require "omq/curve"
#
# Depends on the `natron` shard — add it to your shard.yml:
#
#     dependencies:
#       natron:
#         github: paddor/natron.cr
#
# Use `OMQ::Curve::KeyPair.generate` for long-term keys and Z85 helpers.
# See `OMQ::ZMTP::Mechanism::Curve` for the factory API.
