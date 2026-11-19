require "rails_helper"

RSpec.describe ExtractAttachmentTextJob do
  let(:owner) { create(:user, username: "pdftextowner") }
  let(:org) { create(:organization, owner: owner, domain: "pdftext.com") }
  let(:conv) { create(:conversation, organization: org) }
  let(:msg) { create(:message, conversation: conv, organization: org, body_plain: "Zie bijlage") }
  let(:storage) { instance_double(S3StorageService) }

  # Smallest PDF with a text layer; pdftotext rebuilds the missing xref table.
  def pdf_with(text)
    stream = "BT /F1 12 Tf 72 720 Td (#{text}) Tj ET"
    <<~PDF
      %PDF-1.4
      1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
      2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
      3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj
      4 0 obj << /Length #{stream.bytesize} >> stream
      #{stream}
      endstream endobj
      5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj
      trailer << /Root 1 0 R >>
      %%EOF
    PDF
  end

  before { allow(S3StorageService).to receive(:new).and_return(storage) }

  it "stores the PDF's text and folds it into the message's search vector" do
    skip "pdftotext not installed" unless system("which pdftotext > /dev/null")
    att = create(:attachment, message: msg, organization: org, filename: "aangifte.pdf",
                              content_type: "application/pdf", storage_key: "k/aangifte.pdf")
    allow(storage).to receive(:download).with("k/aangifte.pdf").and_return(pdf_with("Btw-nummer NL827315636B01"))

    described_class.perform_now(att.id)

    expect(att.reload.content_text).to include("Btw-nummer")
    hit = Message.where(id: msg.id).where("search_vector @@ websearch_to_tsquery('simple', 'nummer bijlage')")
    expect(hit).to exist
  end

  it "is enqueued for a new PDF attachment, not for other files" do
    expect {
      create(:attachment, message: msg, organization: org, filename: "a.pdf", content_type: "application/pdf")
    }.to have_enqueued_job(described_class)
    expect {
      create(:attachment, message: msg, organization: org, filename: "a.png", content_type: "image/png")
    }.not_to have_enqueued_job(described_class)
  end

  it "skips sealed attachments" do
    att = create(:attachment, message: msg, organization: org, filename: nil, sealed_filename: "c2VhbGVk",
                              content_type: "application/pdf", storage_key: "k/sealed")
    expect(storage).not_to receive(:download)
    described_class.perform_now(att.id)
  end
end
