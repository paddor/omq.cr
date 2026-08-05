require "../test_helper"
require "../../src/omq/radio_dish"

describe "RADIO/DISH over inproc" do
  it "signals when a dish joins" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      radio = OMQ::RADIO.bind("inproc://rd-subscriber-joined")
      dish = OMQ::DISH.connect("inproc://rd-subscriber-joined")
      dish.join("weather")

      pipe = radio.subscriber_joined.receive
      refute pipe.closed?

      radio.close
      dish.close
    end
  end

  it "delivers only joined groups to the DISH" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      radio = OMQ::RADIO.bind("inproc://rd-basic")
      dish = OMQ::DISH.connect("inproc://rd-basic")
      dish.join("weather")

      radio.subscriber_joined.receive

      radio.publish("sports", "ignored")
      radio.publish("weather", "sunny")
      radio.publish("news", "ignored-too")
      radio.publish("weather", "cloudy")

      msg1 = dish.receive
      assert_equal "weather", String.new(msg1[0])
      assert_equal "sunny", String.new(msg1[1])

      msg2 = dish.receive
      assert_equal "weather", String.new(msg2[0])
      assert_equal "cloudy", String.new(msg2[1])

      radio.close
      dish.close
    end
  end

  it "stops delivering a group after #leave" do
    OMQ::TestHelper.with_timeout(2.seconds) do
      radio = OMQ::RADIO.bind("inproc://rd-leave")
      dish = OMQ::DISH.connect("inproc://rd-leave")
      dish.join("a").join("b")
      radio.subscriber_joined.receive

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

  it "closes subscriber readiness channel on close" do
    radio = OMQ::RADIO.new

    radio.close

    assert radio.subscriber_joined.closed?
  end
end

describe "RADIO/DISH over UDP" do
  it "delivers matching groups" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      dish = OMQ::DISH.bind("udp://127.0.0.1:0")
      dish.join("weather")
      port = dish.port.not_nil!

      radio = OMQ::RADIO.connect("udp://127.0.0.1:#{port}")
      radio.publish("weather", "sunny")

      msg = dish.receive
      assert_equal "weather", String.new(msg[0])
      assert_equal "sunny", String.new(msg[1])

      radio.close
      dish.close
    end
  end

  it "filters unjoined groups locally" do
    OMQ::TestHelper.with_timeout(3.seconds) do
      dish = OMQ::DISH.bind("udp://127.0.0.1:0", read_timeout: 150.milliseconds)
      dish.join("weather")
      port = dish.port.not_nil!

      radio = OMQ::RADIO.connect("udp://127.0.0.1:#{port}")
      radio.publish("news", "ignored")
      radio.publish("weather", "rain")

      msg = dish.receive
      assert_equal "weather", String.new(msg[0])
      assert_equal "rain", String.new(msg[1])
      assert_raises(IO::TimeoutError) { dish.receive }

      radio.close
      dish.close
    end
  end

  it "rejects the wrong UDP roles" do
    assert_raises(OMQ::UnsupportedTransport) do
      OMQ::RADIO.bind("udp://127.0.0.1:0")
    end

    assert_raises(OMQ::UnsupportedTransport) do
      OMQ::DISH.connect("udp://127.0.0.1:9")
    end
  end
end
