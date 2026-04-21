module OMQ
  module Transport
    extend self

    # Periodic PING sender + silence watchdog. Sends a PING every
    # `interval`. After each sleep, if the last-received-frame instant
    # is older than `silence_timeout`, closes the ZMTP connection; the
    # read/write pumps unwind from there.
    #
    # - `ttl` goes into the PING frame (deciseconds, rounded). Peers
    #   honor it as "if you haven't heard from me in this long, I'm
    #   gone" — informational only on our side.
    # - IO errors while sending are treated as "peer gone," close the
    #   connection, and exit the loop.
    def heartbeat_pump(
      zmtp : ZMTP::Connection,
      *,
      interval : Time::Span,
      ttl : Time::Span,
      silence_timeout : Time::Span,
    ) : Nil
      ttl_deci = (ttl.total_milliseconds / 100.0).to_u16
      zmtp.touch_last_received
      loop do
        zmtp.send_ping(ttl_deci)
        sleep interval
        if Time.instant - zmtp.last_received_at > silence_timeout
          zmtp.close
          break
        end
      end
    rescue IO::Error | ProtocolError
      zmtp.close
    end
  end
end
