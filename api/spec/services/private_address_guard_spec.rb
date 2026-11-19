require "rails_helper"

RSpec.describe PrivateAddressGuard do
  describe ".public_ip?" do
    it "blocks loopback, RFC1918, CGNAT and cloud-metadata addresses" do
      %w[127.0.0.1 10.0.0.5 192.168.1.1 172.16.0.1 169.254.169.254 100.64.0.1 ::1].each do |ip|
        expect(described_class.public_ip?(ip)).to be(false), "expected #{ip} blocked"
      end
    end

    it "allows public addresses" do
      expect(described_class.public_ip?("1.1.1.1")).to be(true)
      expect(described_class.public_ip?("8.8.8.8")).to be(true)
      expect(described_class.public_ip?("2606:4700:4700::1111")).to be(true)
    end

    it "sees through IPv6 coats on internal IPv4 targets (mapped, NAT64, 6to4)" do
      %w[::ffff:127.0.0.1 ::ffff:10.0.0.5 ::ffff:169.254.169.254 64:ff9b::a9fe:a9fe 2002:a00:1::1 100::1 2001:db8::1].each do |ip|
        expect(described_class.public_ip?(ip)).to be(false), "expected #{ip} blocked"
      end
    end
  end

  describe ".public_host?" do
    it "is false for an IP literal in a blocked range (no DNS needed)" do
      expect(described_class.public_host?("169.254.169.254")).to be(false)
      expect(described_class.public_host?("127.0.0.1")).to be(false)
    end

    it "is true for a public IP literal" do
      expect(described_class.public_host?("1.1.1.1")).to be(true)
    end

    it "is false for blank/unresolvable hosts" do
      expect(described_class.public_host?("")).to be(false)
      expect(described_class.public_host?(nil)).to be(false)
    end

    it "rejects a host that resolves to a private address" do
      allow(described_class).to receive(:resolve).with("rebind.test").and_return(["10.0.0.1"])
      expect(described_class.public_host?("rebind.test")).to be(false)
    end

    it "rejects a host with any private answer among public ones (all-or-nothing)" do
      allow(described_class).to receive(:resolve).with("mixed.test").and_return(["1.1.1.1", "127.0.0.1"])
      expect(described_class.public_host?("mixed.test")).to be(false)
    end
  end

  # The pinned_* methods resolve once and return the IP to connect to, closing
  # the DNS-rebinding TOCTOU (a host public at check time, private at connect).
  describe ".pinned_public_ip" do
    it "returns the resolved IP when every answer is public" do
      allow(described_class).to receive(:resolve).with("ok.test").and_return(["1.1.1.1"])
      expect(described_class.pinned_public_ip("ok.test")).to eq("1.1.1.1")
    end

    it "prefers an IPv4 answer over IPv6 (no IPv6 route in the cluster)" do
      allow(described_class).to receive(:resolve).with("dual.test").and_return(["2606:4700:3033::ac43:d242", "104.21.1.1"])
      expect(described_class.pinned_public_ip("dual.test")).to eq("104.21.1.1")
    end

    it "returns nil if any answer is private (rebinding defence)" do
      allow(described_class).to receive(:resolve).with("rebind.test").and_return(["1.1.1.1", "10.0.0.1"])
      expect(described_class.pinned_public_ip("rebind.test")).to be_nil
    end

    it "returns the literal for a public IP host without DNS" do
      expect(described_class.pinned_public_ip("1.1.1.1")).to eq("1.1.1.1")
    end

    it "is nil for blank/unresolvable hosts" do
      expect(described_class.pinned_public_ip("")).to be_nil
    end
  end

  describe ".pinned_url" do
    it "returns [uri, ip] for a public http(s) URL" do
      allow(described_class).to receive(:resolve).with("img.test").and_return(["1.1.1.1"])
      uri, ip = described_class.pinned_url("https://img.test/a.png")
      expect(ip).to eq("1.1.1.1")
      expect(uri.host).to eq("img.test")
    end

    it "is nil for a non-http(s) scheme" do
      expect(described_class.pinned_url("ftp://example.com/x")).to be_nil
    end

    it "is nil when the host resolves to a private/metadata address" do
      allow(described_class).to receive(:resolve).with("evil.test").and_return(["169.254.169.254"])
      expect(described_class.pinned_url("http://evil.test/")).to be_nil
    end
  end
end
