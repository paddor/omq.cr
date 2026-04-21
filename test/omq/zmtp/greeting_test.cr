require "../../test_helper"

describe "OMQ::ZMTP::Greeting" do
  it "round-trips" do
    io = IO::Memory.new
    OMQ::ZMTP::Greeting.new("NULL", as_server: true).to_io(io)
    assert_equal 64, io.size
    io.rewind
    g = OMQ::ZMTP::Greeting.from_io(io)
    assert_equal 3_u8, g.major
    assert_equal 1_u8, g.minor
    assert_equal "NULL", g.mechanism
    assert g.as_server?
  end

  it "accepts a ZMTP 3.0 peer" do
    io = IO::Memory.new
    OMQ::ZMTP::Greeting.new(3_u8, 0_u8, "NULL", false).to_io(io)
    io.rewind
    g = OMQ::ZMTP::Greeting.from_io(io)
    assert_equal 3_u8, g.major
    assert_equal 0_u8, g.minor
  end

  it "rejects a ZMTP 2.0 peer after exactly 11 bytes" do
    # signature (10 bytes) + major byte = 0x01 (ZMTP 2.0).
    wire = Bytes.new(11)
    OMQ::ZMTP::SIGNATURE.copy_to(wire)
    wire[10] = 0x01_u8
    io = IO::Memory.new(wire)
    assert_raises(OMQ::UnsupportedVersion) { OMQ::ZMTP::Greeting.from_io(io) }
    # All 11 bytes consumed — not one more.
    assert_equal 11, io.pos
  end

  it "rejects a bad signature" do
    wire = Bytes.new(11, 0x00_u8)
    wire[10] = 0x03_u8
    io = IO::Memory.new(wire)
    assert_raises(OMQ::ProtocolError) { OMQ::ZMTP::Greeting.from_io(io) }
  end

  it "places NULL mechanism name at bytes 12..15 with null padding" do
    io = IO::Memory.new
    OMQ::ZMTP::Greeting.new("NULL", as_server: false).to_io(io)
    bytes = io.to_slice
    assert_equal "NULL", String.new(bytes[12, 4])
    # remaining 16 bytes of the mechanism field are zero
    bytes[16, 16].each { |b| assert_equal 0_u8, b }
  end

  it "encodes as_server at byte 32" do
    srv = IO::Memory.new
    OMQ::ZMTP::Greeting.new("NULL", as_server: true).to_io(srv)
    assert_equal 1_u8, srv.to_slice[32]

    cli = IO::Memory.new
    OMQ::ZMTP::Greeting.new("NULL", as_server: false).to_io(cli)
    assert_equal 0_u8, cli.to_slice[32]
  end
end
