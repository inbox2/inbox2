require "rails_helper"

RSpec.describe DkimKey do
  around do |example|
    original = ENV["DKIM_PRIVATE_KEY"]
    example.run
    ENV["DKIM_PRIVATE_KEY"] = original
  end

  it "reports unconfigured when no key is set" do
    ENV.delete("DKIM_PRIVATE_KEY")
    expect(described_class.configured?).to be(false)
    expect(described_class.rsa).to be_nil
  end

  it "loads an RSA key from the env (with literal \\n escapes)" do
    pem = OpenSSL::PKey::RSA.new(2048).to_pem
    ENV["DKIM_PRIVATE_KEY"] = pem.gsub("\n", '\n')

    expect(described_class.configured?).to be(true)
    expect(described_class.rsa).to be_a(OpenSSL::PKey::RSA)
  end

  it "defaults the selector to inbox2" do
    expect(described_class.selector).to eq("inbox2")
  end
end
