require "../test_helper"

describe "PAIR over inproc" do
  it "sends and receives a single-frame message" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      a = OMQ::PAIR.bind("inproc://pair-1")
      b = OMQ::PAIR.connect("inproc://pair-1")

      a.send("hello")
      msg = b.receive
      assert_equal 1, msg.size
      assert_equal "hello".to_slice, msg[0]

      b.send("world")
      msg2 = a.receive
      assert_equal "world".to_slice, msg2[0]

      a.close
      b.close
    end
  end

  it "delivers multiframe messages preserving order" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      a = OMQ::PAIR.bind("inproc://pair-mf")
      b = OMQ::PAIR.connect("inproc://pair-mf")

      a.send(["one".to_slice, "two".to_slice, "three".to_slice])
      got = b.receive
      assert_equal 3, got.size
      assert_equal "one", String.new(got[0])
      assert_equal "two", String.new(got[1])
      assert_equal "three", String.new(got[2])

      a.close
      b.close
    end
  end

  it "supports << chaining" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      a = OMQ::PAIR.bind("inproc://pair-chain")
      b = OMQ::PAIR.connect("inproc://pair-chain")

      a << "x" << "y"
      assert_equal "x", String.new(b.receive[0])
      assert_equal "y", String.new(b.receive[0])

      a.close
      b.close
    end
  end

  it "raises when connecting to an unbound endpoint" do
    assert_raises(OMQ::InvalidEndpoint) do
      OMQ::PAIR.connect("inproc://nowhere")
    end
  end
end
