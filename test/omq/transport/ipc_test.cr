require "../../test_helper"

private def abs_endpoint(tag : String) : String
  "ipc://@omq-test-#{tag}-#{Process.pid}"
end


private def fs_endpoint(tag : String) : {String, String}
  path = "/tmp/omq-test-#{tag}-#{Process.pid}.sock"
  {"ipc://#{path}", path}
end


describe "PAIR over IPC (filesystem path)" do
  it "round-trips messages and cleans up the socket file" do
    endpoint, path = fs_endpoint("pair-fs")
    File.delete(path) if File.exists?(path)

    OMQ::TestHelper.with_timeout(3.seconds) do
      server = OMQ::PAIR.bind(endpoint)
      client = OMQ::PAIR.connect(endpoint)

      client.send("hello ipc")
      got = server.receive
      assert_equal "hello ipc", String.new(got[0])

      server.send("reply ipc")
      reply = client.receive
      assert_equal "reply ipc", String.new(reply[0])

      client.close
      server.close
    end

    refute File.exists?(path)
  end
end


describe "PAIR over IPC (abstract namespace)" do
  it "round-trips without touching the filesystem" do
    endpoint = abs_endpoint("pair-abs")

    OMQ::TestHelper.with_timeout(3.seconds) do
      server = OMQ::PAIR.bind(endpoint)
      client = OMQ::PAIR.connect(endpoint)

      client.send("hi")
      got = server.receive
      assert_equal "hi", String.new(got[0])

      client.close
      server.close
    end
  end
end


describe "REQ/REP over IPC" do
  it "round-trips requests and replies" do
    endpoint = abs_endpoint("rr-abs")

    OMQ::TestHelper.with_timeout(3.seconds) do
      rep = OMQ::REP.bind(endpoint)
      req = OMQ::REQ.connect(endpoint)

      10.times do |i|
        req.send("q-#{i}")
        got = rep.receive
        assert_equal "q-#{i}", String.new(got[0])
        rep.send("a-#{i}")
        reply = req.receive
        assert_equal "a-#{i}", String.new(reply[0])
      end

      req.close
      rep.close
    end
  end
end
