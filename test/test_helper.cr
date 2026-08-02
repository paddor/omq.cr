require "minitest/autorun"
require "../src/omq"

class Minitest::Test
  def before_setup
    super
    OMQ::Transport::Inproc.reset!
  end
end

module OMQ::TestHelper
  # Glue a separate read IO and write IO into one duplex IO.
  class DuplexIO < IO
    def initialize(@read : IO, @write : IO)
    end

    def read(slice : Bytes) : Int32
      @read.read(slice)
    end

    def write(slice : Bytes) : Nil
      @write.write(slice)
    end

    def flush : Nil
      @write.flush
    end

    def close : Nil
      @read.close
      @write.close
    end
  end

  # Fail the current test if `block` hasn't finished after `span`.
  def self.with_timeout(span : Time::Span, &block)
    done = Channel(Exception?).new(1)
    spawn do
      begin
        block.call
        done.send(nil)
      rescue ex
        done.send(ex)
      end
    end
    select
    when result = done.receive
      raise result.not_nil! if result
    when timeout(span)
      raise "timed out after #{span}"
    end
  end

  def self.wait_until(span : Time::Span = 2.seconds, interval : Time::Span = 1.millisecond, &block : -> Bool) : Nil
    deadline = Time.instant + span
    until block.call
      raise "timed out waiting for condition" if Time.instant >= deadline
      sleep interval
    end
  end

  def self.free_tcp_port : Int32
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close
    port
  end

  def self.restart_bind_tcp(klass : T.class, port : Int32) : T forall T
    deadline = Time.instant + 2.seconds
    loop do
      begin
        return klass.bind("tcp://127.0.0.1:#{port}", linger: 0.seconds)
      rescue ex : IO::Error
        raise ex if Time.instant >= deadline
        sleep 1.millisecond
      end
    end
  end

  def self.wait_disconnected(socket : OMQ::Socket) : Nil
    wait_until { socket.peer_count.zero? }
  end

  def self.wait_monitor_event(
    events : Channel(OMQ::MonitorEvent),
    kind : OMQ::MonitorEvent::Kind,
    span : Time::Span = 2.seconds,
  ) : OMQ::MonitorEvent
    deadline = Time.instant + span
    loop do
      remaining = deadline - Time.instant
      raise "timed out waiting for monitor event #{kind}" unless remaining.positive?

      select
      when event = events.receive?
        raise "monitor closed while waiting for #{kind}" unless event
        return event if event.kind == kind
      when timeout(remaining)
        raise "timed out waiting for monitor event #{kind}"
      end
    end
  end
end
