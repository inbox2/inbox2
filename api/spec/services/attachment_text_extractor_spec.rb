require "rails_helper"

RSpec.describe AttachmentTextExtractor do
  let(:owner) { create(:user, username: "atextowner") }
  let(:org) { create(:organization, owner: owner, domain: "atext.com") }
  let(:conv) { create(:conversation, organization: org) }
  let(:msg) { create(:message, conversation: conv, organization: org) }

  describe "#extract (spec 6.3.5)" do
    it "extracts text from plain text attachment" do
      att = Attachment.create!(message: msg, organization: org, filename: "readme.txt", content_type: "text/plain")
      extractor = described_class.new(att)
      result = extractor.extract("Hello world, this is a test document.")
      expect(result).to eq("Hello world, this is a test document.")
    end

    it "strips HTML tags from HTML attachments" do
      att = Attachment.create!(message: msg, organization: org, filename: "page.html", content_type: "text/html")
      extractor = described_class.new(att)
      result = extractor.extract("<html><body><h1>Title</h1><p>Content here</p></body></html>")
      expect(result).to include("Title")
      expect(result).to include("Content here")
      expect(result).not_to include("<h1>")
    end

    it "strips script and style tags from HTML" do
      att = Attachment.create!(message: msg, organization: org, filename: "page.html", content_type: "text/html")
      extractor = described_class.new(att)
      result = extractor.extract("<html><script>alert('xss')</script><style>.a{color:red}</style><p>Safe</p></html>")
      expect(result).to include("Safe")
      expect(result).not_to include("alert")
      expect(result).not_to include("color")
    end

    it "extracts text from CSV files" do
      att = Attachment.create!(message: msg, organization: org, filename: "data.csv", content_type: "text/csv")
      extractor = described_class.new(att)
      result = extractor.extract("name,email\nJohn,john@example.com")
      expect(result).to include("john@example.com")
    end

    it "extracts from files with text extensions regardless of content_type" do
      att = Attachment.create!(message: msg, organization: org, filename: "config.yml", content_type: "application/octet-stream")
      extractor = described_class.new(att)
      result = extractor.extract("database:\n  host: localhost")
      expect(result).to include("localhost")
    end

    it "returns nil for non-searchable binary files" do
      att = Attachment.create!(message: msg, organization: org, filename: "image.png", content_type: "image/png")
      extractor = described_class.new(att)
      expect(extractor.extract("binary data")).to be_nil
    end

    it "truncates very long text" do
      att = Attachment.create!(message: msg, organization: org, filename: "big.txt", content_type: "text/plain")
      extractor = described_class.new(att)
      long_text = "x" * 200_000
      result = extractor.extract(long_text)
      expect(result.length).to be <= AttachmentTextExtractor::MAX_TEXT_LENGTH
    end

    it "returns nil for blank content" do
      att = Attachment.create!(message: msg, organization: org, filename: "empty.txt", content_type: "text/plain")
      extractor = described_class.new(att)
      expect(extractor.extract("")).to be_nil
    end
  end
end
