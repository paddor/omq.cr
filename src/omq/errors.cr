module OMQ
  class Error < Exception
  end

  class ClosedError < Error
  end

  class InvalidEndpoint < Error
  end

  class UnsupportedTransport < Error
  end

  class NotImplementedError < Error
  end

  class ProtocolError < Error
  end

  class UnsupportedVersion < ProtocolError
  end

  class HandshakeFailed < ProtocolError
  end
end
