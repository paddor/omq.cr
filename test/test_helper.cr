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
end
