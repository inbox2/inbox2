require "rails_helper"

# Disk::Storage settings and the provider table (build guide 10b): Garage in
# development and test, Cloudflare R2 in production, Amazon S3 supported.
RSpec.describe Disk::Storage do
  let(:keys) { { "DISK_S3_ACCESS_KEY" => "AK", "DISK_S3_SECRET_KEY" => "SK", "DISK_S3_BUCKET" => "acme-disk" } }

  def query(url) = Rack::Utils.parse_query(URI(url).query)

  it "is Garage by default, falling back to the attachments store's settings" do
    expect(described_class.config({})).to include(provider: "garage", endpoint: "http://localhost:4900",
                                                  force_path_style: true, disk_bucket: "inbox2-test-disk",
                                                  disk_public_endpoint: "http://localhost:4900")
  end

  it "defaults to R2 in production" do
    allow(Rails.env).to receive(:production?).and_return(true)
    expect(described_class.config({})[:provider]).to eq("r2")
  end

  it "refuses an unknown provider" do
    expect { described_class.config("DISK_STORAGE_PROVIDER" => "ftp") }.to raise_error(ArgumentError, /garage, r2, s3/)
  end

  describe "r2" do
    let(:endpoint) { "https://abc123.r2.cloudflarestorage.com" }
    let(:config) { described_class.config(keys.merge("DISK_STORAGE_PROVIDER" => "r2", "DISK_S3_ENDPOINT" => endpoint)) }
    let(:storage) { described_class.new(config) }

    it "uses region auto, path-style addressing and signs on the S3 API endpoint" do
      expect(config).to include(region: "auto", force_path_style: true, endpoint: endpoint, disk_public_endpoint: endpoint)
      expect(storage.part_url("org_x/abc", "up1", 3)).to start_with("#{endpoint}/acme-disk/org_x/abc?")
    end

    it "sends no default checksums, so presigned part URLs carry none the browser cannot satisfy" do
      client = storage.instance_variable_get(:@client)
      expect(client.config.request_checksum_calculation).to eq("when_required")
      expect(client.config.response_checksum_validation).to eq("when_required")
      params = query(storage.part_url("k", "up1", 1))
      expect(params.keys.grep(/checksum/i)).to be_empty
      expect(params["X-Amz-SignedHeaders"]).to eq("host")
    end

    it "requires equal parts and does not create the bucket through the API" do
      expect(described_class::PROVIDERS["r2"]).to include(equal_parts: true, create_bucket: false)
    end
  end

  describe "s3" do
    it "is AWS with virtual-hosted addressing when no endpoint is given" do
      config = described_class.config(keys.merge("DISK_STORAGE_PROVIDER" => "s3", "DISK_S3_REGION" => "eu-central-1"))
      expect(config).to include(endpoint: nil, disk_public_endpoint: nil, region: "eu-central-1", force_path_style: false)
      url = described_class.new(config).part_url("org_x/abc", "up1", 3)
      expect(url).to start_with("https://acme-disk.s3.eu-central-1.amazonaws.com/org_x/abc?")
      expect(query(url)).to include("partNumber" => "3", "uploadId" => "up1")
      expect(described_class::PROVIDERS["s3"]).to include(ranged_disposition: true, create_bucket: true)
    end
  end

  it "signs for a separate public endpoint when one is given" do
    config = described_class.config("DISK_S3_ENDPOINT" => "http://garage:3900", "DISK_S3_PUBLIC_ENDPOINT" => "https://files.example")
    expect(config).to include(endpoint: "http://garage:3900", disk_public_endpoint: "https://files.example")
    expect(described_class.new(config).get_url("k")).to start_with("https://files.example/inbox2-test-disk/k?")
  end
end
