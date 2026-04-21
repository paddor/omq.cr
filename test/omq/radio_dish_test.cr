require "../test_helper"
require "../../src/omq/radio_dish"

describe "RADIO/DISH over inproc" do
  it "delivers only joined groups to the DISH" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      radio = OMQ::RADIO.bind("inproc://rd-basic")
      dish  = OMQ::DISH.connect("inproc://rd-basic")
      dish.join("weather")

      # Give attach a chance to run so the join registers before publishing.
      Fiber.yield

      radio.publish("sports", "ignored")
      radio.publish("weather", "sunny")
      radio.publish("news",    "ignored-too")
      radio.publish("weather", "cloudy")

      msg1 = dish.receive
      assert_equal "weather", String.new(msg1[0])
      assert_equal "sunny",   String.new(msg1[1])

      msg2 = dish.receive
      assert_equal "weather", String.new(msg2[0])
      assert_equal "cloudy",  String.new(msg2[1])

      radio.close
      dish.close
    end
  end


  it "stops delivering a group after #leave" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      radio = OMQ::RADIO.bind("inproc://rd-leave")
      dish  = OMQ::DISH.connect("inproc://rd-leave")
      dish.join("a").join("b")
      Fiber.yield

      radio.publish("a", "first")
      assert_equal "first", String.new(dish.receive[1])

      dish.leave("a")
      radio.publish("a", "dropped")
      radio.publish("b", "kept")
      assert_equal "kept", String.new(dish.receive[1])

      radio.close
      dish.close
    end
  end
end
