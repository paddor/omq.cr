require "./system_test_helper"

private def lz4_ruby_available?
  OMQ::SystemTestHelper.ruby_can_require?("omq/lz4")
end

private def lz4_interop_payload(mode : String, i : Int32) : Bytes
  case mode
  when "dict"
    ("event=login user=alice payload=#{i}" * 8).to_slice
  when "auto_dict"
    %({"event":"login","user":"user_#{i}","ts":"2026-08-03T00:00:00.#{i}Z","region":"us-east-1","status":200}).to_slice
  else
    "lz4-work-#{i}".to_slice
  end
end

describe "Ruby LZ4 PULL ↔ Crystal PUSH over lz4+tcp" do
  it "pushes plain and dict-compressed messages to Ruby" do
    skip "ruby + omq/lz4 gem not installed" unless lz4_ruby_available?

    OMQ::SystemTestHelper.with_timeout(5.seconds) do
      process, endpoint = OMQ::SystemTestHelper.spawn_ruby_with_endpoint("lz4_pull_server.rb")

      begin
        dict = ("event=login user=alice payload=" * 10).to_slice
        push = OMQ::PUSH.connect(endpoint, dict: dict)

        3.times { |i| push.send(lz4_interop_payload("dict", i)) }

        received = OMQ::SystemTestHelper.read_lines(process, 3)
        assert_equal 3, received.size
        3.times { |i| assert_equal String.new(lz4_interop_payload("dict", i)), received[i] }

        push.linger = 2.seconds
        push.close
      ensure
        OMQ::SystemTestHelper.shutdown(process)
      end
    end
  end
end

describe "Crystal LZ4 PULL ↔ Ruby PUSH over lz4+tcp" do
  it "receives dict-compressed messages from Ruby" do
    skip "ruby + omq/lz4 gem not installed" unless lz4_ruby_available?

    OMQ::SystemTestHelper.with_timeout(5.seconds) do
      pull = OMQ::PULL.bind("lz4+tcp://127.0.0.1:0", read_timeout: 2.seconds)
      endpoint = "lz4+tcp://127.0.0.1:#{pull.port.not_nil!}"
      ruby = OMQ::SystemTestHelper.ruby_bin.not_nil!
      script = File.join(OMQ::SystemTestHelper::SCRIPTS_DIR, "lz4_push_client.rb")
      process = Process.new(ruby, [script, endpoint, "dict", "3"], input: :pipe, output: :pipe, error: :inherit)

      begin
        assert_equal "READY", process.output.gets.try(&.chomp)

        3.times do |i|
          assert_equal lz4_interop_payload("dict", i), pull.receive[0]
        end
      ensure
        OMQ::SystemTestHelper.shutdown(process)
        pull.close
      end
    end
  end

  it "receives auto-dict messages from Ruby" do
    skip "ruby + omq/lz4 gem not installed" unless lz4_ruby_available?

    OMQ::SystemTestHelper.with_timeout(5.seconds) do
      pull = OMQ::PULL.bind("lz4+tcp://127.0.0.1:0", read_timeout: 2.seconds)
      endpoint = "lz4+tcp://127.0.0.1:#{pull.port.not_nil!}"
      ruby = OMQ::SystemTestHelper.ruby_bin.not_nil!
      script = File.join(OMQ::SystemTestHelper::SCRIPTS_DIR, "lz4_push_client.rb")
      process = Process.new(ruby, [script, endpoint, "auto_dict", "8"], input: :pipe, output: :pipe, error: :inherit)

      begin
        assert_equal "READY", process.output.gets.try(&.chomp)

        8.times do |i|
          assert_equal lz4_interop_payload("auto_dict", i), pull.receive[0]
        end
      ensure
        OMQ::SystemTestHelper.shutdown(process)
        pull.close
      end
    end
  end
end
