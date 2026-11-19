require "rails_helper"

RSpec.describe MailHeaderEncoding do
  describe ".encode_text" do
    it "passes ASCII through untouched" do
      expect(described_class.encode_text("Hello")).to eq("Hello")
    end

    it "B-encodes non-ASCII text" do
      expect(described_class.encode_text("café")).to eq("=?UTF-8?B?Y2Fmw6k=?=")
    end

    it "handles nil" do
      expect(described_class.encode_text(nil)).to be_nil
    end

    it "folds long non-Latin text into encoded-words within the RFC 2047 cap" do
      subject = "订" * 60 # 180 UTF-8 bytes — one encoded-word would be 252 chars
      words = described_class.encode_text(subject).split("\r\n ")

      expect(words.size).to be > 1
      words.each do |word|
        expect(word.length).to be <= 75
        expect(word).to start_with("=?UTF-8?B?").and end_with("?=")
        # Each encoded-word must decode standalone — a multi-byte character may
        # never straddle two of them.
        expect(Base64.strict_decode64(word[10..-3]).force_encoding("UTF-8")).to be_valid_encoding
      end
      rejoined = words.map { |w| Base64.strict_decode64(w[10..-3]) }.join.force_encoding("UTF-8")
      expect(rejoined).to eq(subject)
    end

    it "normalizes to NFC so decomposed input matches what senders transmit" do
      decomposed = "أ" # alef + combining hamza above
      expect(described_class.encode_text(decomposed)).to eq(described_class.encode_text("أ"))
    end
  end

  describe ".encode_param" do
    it "quotes ASCII values plainly" do
      expect(described_class.encode_param("filename", "report.pdf")).to eq('filename="report.pdf"')
    end

    it "uses RFC 2231 extended syntax for non-ASCII, never an encoded-word" do
      result = described_class.encode_param("filename", "الميزانية.pdf")
      expect(result).to start_with("filename*=UTF-8''")
      expect(result).not_to include("=?UTF-8?B?")
      expect(result).to end_with(".pdf") # unreserved characters stay literal
    end
  end

  describe ".split_addresses" do
    it "splits on top-level commas only" do
      expect(described_class.split_addresses('"Eryigit, Ömer" <o@x.nl>, b@y.com'))
        .to eq(['"Eryigit, Ömer" <o@x.nl>', "b@y.com"])
    end

    it "returns empty for blank input" do
      expect(described_class.split_addresses(nil)).to eq([])
      expect(described_class.split_addresses("")).to eq([])
    end
  end

  describe ".encode_address_header" do
    it "encodes only the display-name part of non-ASCII mailboxes" do
      expect(described_class.encode_address_header('Ahmet <a@x.nl>, "Ömer Eryigit" <o@x.nl>'))
        .to eq("Ahmet <a@x.nl>, =?UTF-8?B?w5ZtZXIgRXJ5aWdpdA==?= <o@x.nl>")
    end

    it "leaves ASCII lists untouched" do
      expect(described_class.encode_address_header("a@x.nl, Bob <b@y.com>"))
        .to eq("a@x.nl, Bob <b@y.com>")
    end
  end

  describe ".bare_addresses" do
    it "extracts addr-specs from mixed mailbox forms" do
      expect(described_class.bare_addresses('"Ömer Eryigit" <o@x.nl>, b@y.com, Carol <c@z.org>'))
        .to eq(["o@x.nl", "b@y.com", "c@z.org"])
    end
  end
end
