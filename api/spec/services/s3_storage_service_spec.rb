require "rails_helper"

RSpec.describe S3StorageService do
  # These tests run against the actual Garage S3 service if available,
  # or gracefully skip if not. Integration tests verify the real flow.

  describe "#initialize" do
    it "loads config from storage.yml" do
      # May fail if Garage isn't running — that's expected in CI without Docker
      service = described_class.new rescue nil
      skip "S3 service unavailable" unless service
      expect(service).to be_a(S3StorageService)
    end
  end

  describe "#upload and #download" do
    it "round-trips data through S3" do
      service = described_class.new rescue nil
      skip "S3 service unavailable" unless service

      data = "Hello, this is test attachment content."
      key = service.upload(data, filename: "test.txt", content_type: "text/plain", organization_key: "org_test")

      expect(key).to include("org_test")
      expect(key).to include("test.txt")

      downloaded = service.download(key)
      expect(downloaded).to eq(data)

      # Cleanup
      service.delete(key)
      expect(service.exists?(key)).to be false
    end
  end

  describe "#presigned_url" do
    it "generates a URL for the object" do
      service = described_class.new rescue nil
      skip "S3 service unavailable" unless service

      key = service.upload("test data", filename: "url_test.txt")
      url = service.presigned_url(key, expires_in: 60)

      expect(url).to include(key)
      expect(url).to include("X-Amz-Signature")

      service.delete(key)
    end
  end

  describe "#exists?" do
    it "returns false for non-existent keys" do
      service = described_class.new rescue nil
      skip "S3 service unavailable" unless service

      expect(service.exists?("nonexistent/key/file.txt")).to be false
    end
  end
end
