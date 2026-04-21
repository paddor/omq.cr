require "../test_helper"
require "../../src/omq/scatter_gather"

describe "SCATTER/GATHER over inproc" do
  it "delivers single-frame messages end-to-end" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      g = OMQ::GATHER.bind("inproc://sg-basic")
      s = OMQ::SCATTER.connect("inproc://sg-basic")

      s.send("hello")
      assert_equal "hello", String.new(g.receive[0])

      s.close
      g.close
    end
  end


  it "round-robins across multiple SCATTER senders" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      g  = OMQ::GATHER.bind("inproc://sg-rr")
      s1 = OMQ::SCATTER.connect("inproc://sg-rr")
      s2 = OMQ::SCATTER.connect("inproc://sg-rr")

      s1.send("a")
      s2.send("b")

      got = [String.new(g.receive[0]), String.new(g.receive[0])].sort
      assert_equal ["a", "b"], got

      s1.close
      s2.close
      g.close
    end
  end
end
