require "./system_test_helper"

private def zstd_ruby_available?
  OMQ::SystemTestHelper.ruby_can_require?("omq/zstd")
end

private def zstd_interop_payload(mode : String, i : Int32) : Bytes
  case mode
  when "dict"
    (%({"event":"login","user":"user_#{i}","region":"us-east-1","status":200}) * 20).to_slice
  when "auto_dict"
    body = "field=#{i % 16} region=us-east-1 status=200 " * 45
    %({"event":"login","user":"user_#{i % 16}","payload":"#{body}"}).to_slice
  else
    "zstd-work-#{i}".to_slice
  end
end

private def zstd_interop_dict : Bytes
  trainer = Zinc::DictTrainer.new(2048)
  40.times { |i| trainer.add_sample(zstd_interop_payload("dict", i)) }
  trainer.train
end

describe "Ruby Zstd PULL ↔ Crystal PUSH over zstd+tcp" do
  it "receives plaintext and dict-compressed messages from Crystal" do
    skip "ruby + omq/zstd gem not installed" unless zstd_ruby_available?

    OMQ::SystemTestHelper.with_timeout(5.seconds) do
      process, endpoint = OMQ::SystemTestHelper.spawn_ruby_with_endpoint("zstd_pull_server.rb")

      begin
        push = OMQ::PUSH.connect(endpoint, zstd_dict: zstd_interop_dict)

        push.send(zstd_interop_payload("plain", 0))
        3.times { |i| push.send(zstd_interop_payload("dict", i)) }

        received = OMQ::SystemTestHelper.read_lines(process, 4)
        assert_equal String.new(zstd_interop_payload("plain", 0)), received[0]
        3.times { |i| assert_equal String.new(zstd_interop_payload("dict", i)), received[i + 1] }

        push.linger = 2.seconds
        push.close
      ensure
        OMQ::SystemTestHelper.shutdown(process)
      end
    end
  end
end

describe "Crystal Zstd PULL ↔ Ruby PUSH over zstd+tcp" do
  it "receives dict-compressed messages from Ruby" do
    skip "ruby + omq/zstd gem not installed" unless zstd_ruby_available?

    OMQ::SystemTestHelper.with_timeout(5.seconds) do
      pull = OMQ::PULL.bind("zstd+tcp://127.0.0.1:0", read_timeout: 2.seconds)
      endpoint = "zstd+tcp://127.0.0.1:#{pull.port.not_nil!}"
      ruby = OMQ::SystemTestHelper.ruby_bin.not_nil!
      script = File.join(OMQ::SystemTestHelper::SCRIPTS_DIR, "zstd_push_client.rb")
      process = Process.new(ruby, [script, endpoint, "dict", "3"], input: :pipe, output: :pipe, error: :inherit)

      begin
        assert_equal "READY", process.output.gets.try(&.chomp)

        3.times do |i|
          assert_equal zstd_interop_payload("dict", i), pull.receive[0]
        end
      ensure
        OMQ::SystemTestHelper.shutdown(process)
        pull.close
      end
    end
  end

  it "receives Ruby auto-dict messages" do
    skip "ruby + omq/zstd gem not installed" unless zstd_ruby_available?

    OMQ::SystemTestHelper.with_timeout(8.seconds) do
      count = 70
      pull = OMQ::PULL.bind("zstd+tcp://127.0.0.1:0", read_timeout: 2.seconds)
      endpoint = "zstd+tcp://127.0.0.1:#{pull.port.not_nil!}"
      ruby = OMQ::SystemTestHelper.ruby_bin.not_nil!
      script = File.join(OMQ::SystemTestHelper::SCRIPTS_DIR, "zstd_push_client.rb")
      process = Process.new(ruby, [script, endpoint, "auto_dict", count.to_s], input: :pipe, output: :pipe, error: :inherit)

      begin
        assert_equal "READY", process.output.gets.try(&.chomp)

        count.times do |i|
          assert_equal zstd_interop_payload("auto_dict", i), pull.receive[0]
        end
      ensure
        OMQ::SystemTestHelper.shutdown(process)
        pull.close
      end
    end
  end
end
