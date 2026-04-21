require "./omq/version"
require "./omq/errors"
require "./omq/constants"
require "./omq/zmtp/frame"
require "./omq/zmtp/greeting"
require "./omq/zmtp/command"
require "./omq/zmtp/mechanism"
require "./omq/options"
require "./omq/socket"
require "./omq/transport/inproc"
require "./omq/pair"

# Pure-Crystal ZeroMQ (ZMTP 3.1). Interoperable with libzmq, pyzmq, CZMQ,
# and the Ruby `omq` gem. No libzmq, no FFI.
module OMQ
end
