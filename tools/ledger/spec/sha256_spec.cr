require "./spec_helper"

# NIST FIPS 180-2 test vectors, so the expected values come from the standard
# rather than from another implementation on this machine.
describe GalaxyLedger::SHA256 do
  describe ".hexdigest" do
    it "hashes the empty string" do
      GalaxyLedger::SHA256.hexdigest("").should eq(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    end

    it "hashes \"abc\"" do
      GalaxyLedger::SHA256.hexdigest("abc").should eq(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    end

    it "hashes the two-block message" do
      GalaxyLedger::SHA256.hexdigest(
        "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
      ).should eq(
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    end

    it "hashes a million \"a\"s" do
      GalaxyLedger::SHA256.hexdigest("a" * 1_000_000).should eq(
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    end

    it "hashes bytes the same as the equivalent string" do
      GalaxyLedger::SHA256.hexdigest("é 漢字 🚀".to_slice).should eq(
        GalaxyLedger::SHA256.hexdigest("é 漢字 🚀"))
    end
  end

  describe "#update" do
    it "gives the one-shot result when fed in pieces" do
      message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
      digest = GalaxyLedger::SHA256.new
      message.each_char.each_slice(7) { |part| digest.update(part.join) }
      digest.hexfinal.should eq(GalaxyLedger::SHA256.hexdigest(message))
    end
  end
end
