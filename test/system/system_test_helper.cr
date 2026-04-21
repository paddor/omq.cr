require "minitest/autorun"
require "../../src/omq"


module OMQ::SystemTestHelper

  # Ruby interpreter. Overridable via OMQ_RUBY_BIN; otherwise `ruby`
  # is resolved from PATH.
  RUBY_BIN = ENV["OMQ_RUBY_BIN"]? || "ruby"


  SCRIPTS_DIR = File.expand_path("scripts", __DIR__)


  # Cached ruby path (nil = `ruby` can't load the `omq` gem).
  @@ruby_bin : String? = nil
  @@probed = false


  def self.ruby_bin : String?
    return @@ruby_bin if @@probed
    @@probed = true
    output = IO::Memory.new
    status = Process.run(RUBY_BIN, ["-r", "omq", "-e", "print OMQ::VERSION"], output: output, error: Process::Redirect::Close)
    if status.success? && !output.to_s.empty?
      @@ruby_bin = RUBY_BIN
    end
  rescue
    nil
  end


  # Spawn a Ruby script and read the `PORT=<n>` it prints on its first
  # stdout line. Returns `{process, port}`. The process keeps running
  # until `stdin.close` (EOF) or `process.terminate`.
  def self.spawn_ruby_with_port(script : String, args : Array(String) = [] of String) : {Process, Int32}
    ruby = ruby_bin || raise "ruby + omq gem not available"
    script_path = File.join(SCRIPTS_DIR, script)
    process = Process.new(ruby, [script_path] + args, input: :pipe, output: :pipe, error: :inherit)
    line = process.output.gets
    raise "ruby script exited before printing PORT" unless line
    raise "ruby script did not print PORT line: #{line.inspect}" unless line.starts_with?("PORT=")
    port = line.lchop("PORT=").strip.to_i
    {process, port}
  end


  # Read lines from the process's stdout until EOF or `count` lines
  # have been collected.
  def self.read_lines(process : Process, count : Int32) : Array(String)
    lines = [] of String
    count.times do
      line = process.output.gets
      break unless line
      lines << line.chomp
    end
    lines
  end


  def self.shutdown(process : Process) : Nil
    process.input.close rescue nil
    process.wait rescue nil
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
