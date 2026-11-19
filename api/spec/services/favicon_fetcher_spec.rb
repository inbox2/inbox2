require "rails_helper"

RSpec.describe FaviconFetcher do
  subject(:fetcher) { described_class.new("example.com") }

  describe "#extract_candidates (ranking)" do
    let(:html) do
      <<~HTML
        <html><head>
          <link rel="icon" href="/favicon-16.png" sizes="16x16">
          <link rel="apple-touch-icon" href="/apple-180.png">
          <link rel="icon" href="/favicon-64.png" sizes="64x64">
          <meta property="og:image" content="https://cdn.example.com/og.png">
        </head></html>
      HTML
    end

    it "orders highest-resolution first and resolves relative URLs" do
      candidates = fetcher.send(:extract_candidates, html, "https://example.com")
      # apple-touch (180) > 64x64 > og:image (150) > 16x16
      expect(candidates.first).to eq("https://example.com/apple-180.png")
      expect(candidates).to include("https://cdn.example.com/og.png")
      expect(candidates).to include("https://example.com/favicon-64.png")
      expect(candidates.index("https://example.com/favicon-64.png"))
        .to be < candidates.index("https://example.com/favicon-16.png")
    end

    it "returns [] for HTML with no icons" do
      expect(fetcher.send(:extract_candidates, "<html></html>", "https://example.com")).to eq([])
    end
  end
end
