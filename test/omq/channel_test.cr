require "../test_helper"
require "../../src/omq/channel"

describe "CHANNEL over inproc" do
  it "sends and receives bidirectionally with a single peer" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      a = OMQ::CHANNEL.bind("inproc://ch-basic")
      b = OMQ::CHANNEL.connect("inproc://ch-basic")

      a.send("hi")
      assert_equal "hi", String.new(b.receive[0])

      b.send("ho")
      assert_equal "ho", String.new(a.receive[0])

      a.close
      b.close
    end
  end


  it "drops a second connector" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      a  = OMQ::CHANNEL.bind("inproc://ch-solo")
      b1 = OMQ::CHANNEL.connect("inproc://ch-solo")
      b2 = OMQ::CHANNEL.connect("inproc://ch-solo")

      a.send("to b1")
      assert_equal "to b1", String.new(b1.receive[0])

      # b2's pipe should have been closed by the strategy; sending
      # from a only ever reaches b1.
      refute_nil b2

      a.close
      b1.close
      b2.close
    end
  end
end
