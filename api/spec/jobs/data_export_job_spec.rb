require "rails_helper"
require "zip"

# spec 11.3.3 / A15.6 — the organisation data export zip.
RSpec.describe DataExportJob do
  let(:owner) { create(:user) }
  let(:org) { create(:organization, owner: owner, domain: "export.test") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:storage) { instance_double(S3StorageService) }
  let(:zip_path) { Rails.root.join("tmp", "data_export_spec_#{SecureRandom.hex(4)}.zip").to_s }
  let(:export) { org.data_exports.create!(requested_by: membership) }

  before do
    allow(S3StorageService).to receive(:new).and_return(storage)
    allow(storage).to receive(:upload) do |io, **|
      File.binwrite(zip_path, io.read)
      "#{org.key}/export.zip"
    end
    allow(storage).to receive(:download).with("att/report.txt").and_return("attachment bytes")
  end

  after { FileUtils.rm_f(zip_path) }

  def entries
    Zip::File.open(zip_path) { |zip| zip.entries.to_h { |e| [e.name, e.get_input_stream.read] } }
  end

  context "positive" do
    before do
      main = org.domains.first
      other = create(:domain, organization: org, name: "second.test")
      conv = create(:conversation, organization: org, domain: main)
      create(:message, conversation: conv, subject: "Plain", body_plain: "Hi\nFrom the start of a line\nbye")
      html = create(:message, conversation: conv, subject: "Rich", body_plain: "text", body_html: "<p>html</p>")
      Attachment.create!(organization: org, message: html, filename: "report.txt", content_type: "text/plain", storage_key: "att/report.txt")
      create(:message, conversation: conv, is_draft: true, subject: "Draft, left out")
      # A member's imported history is private to them — not the admin's to export.
      importer = create(:membership, user: create(:user), organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
      private_conv = create(:conversation, organization: org, domain: main, private: true, owner_membership_id: importer.id)
      create(:message, conversation: private_conv, subject: "Imported and private")

      sealed_conv = create(:conversation, organization: org, domain: other)
      create(:message, conversation: sealed_conv, encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V1,
                       from_address: nil, subject: nil, body_plain: nil, body_ciphertext: "CIPHERTEXT==", body_nonce: "nonce")

      calendar = Calendar.primary_for(org, membership)
      CalendarEvent.create!(calendar: calendar, organization: org, title: "Standup",
                            start_at: Time.utc(2026, 10, 1, 9), end_at: Time.utc(2026, 10, 1, 9, 15),
                            recurrence_rule: "FREQ=WEEKLY;BYDAY=TH;COUNT=4")
      CalendarEvent.create!(calendar: calendar, organization: org, title: "Lunch",
                            start_at: Time.utc(2026, 10, 2, 12), end_at: Time.utc(2026, 10, 2, 13))
    end

    it "builds a zip with an mbox per domain, an .ics per calendar and a README" do
      described_class.perform_now(export.id)
      export.reload

      expect(export.status).to eq(DataExport::STATUS_READY)
      expect(export.storage_key).to eq("#{org.key}/export.zip")
      expect(export.byte_size).to eq(File.size(zip_path))
      expect(export.expires_at).to be_within(1.minute).of(Time.current + DataExport::RETENTION)
      expect(export.counts).to include("messages" => 3, "sealed_messages" => 1, "events" => 2, "attachments" => 1)

      files = entries
      mbox = files.fetch("export.test/mail.mbox")
      expect(mbox.scan(/^From /).size).to eq(2)
      expect(mbox).to include(">From the start of a line")
      expect(mbox).to include("Subject: Rich", "multipart/mixed", "multipart/alternative", "filename=report.txt")
      expect(mbox).not_to include("Draft, left out")
      expect(mbox).not_to include("Imported and private")

      sealed = files.fetch("second.test/mail.mbox")
      expect(sealed.scan(/^From /).size).to eq(1)
      expect(sealed).to include("X-Inbox2-Encryption: sealed_box_v1", "sealed.json")

      ics_name = files.keys.find { |n| n.start_with?("calendars/") }
      calendars = Icalendar::Calendar.parse(files.fetch(ics_name))
      expect(calendars.size).to eq(1)
      events = calendars.first.events
      expect(events.map { |e| e.summary.to_s }).to contain_exactly("Standup", "Lunch")
      expect(events.find { |e| e.summary.to_s == "Standup" }.rrule.first.frequency).to eq("WEEKLY")

      expect(files.fetch("README.txt")).to include("3 messages", "Apple Mail", ".ics")
    end
  end

  context "negative" do
    it "marks the export failed with the error when storage rejects the upload" do
      allow(storage).to receive(:upload).and_raise(Aws::S3::Errors::ServiceError.new(nil, "bucket is gone"))

      described_class.perform_now(export.id)
      export.reload
      expect(export.status).to eq(DataExport::STATUS_FAILED)
      expect(export.error).to eq("bucket is gone")
    end

    it "does nothing for an export that isn't queued" do
      export.update!(status: DataExport::STATUS_EXPIRED)
      described_class.perform_now(export.id)
      expect(storage).not_to have_received(:upload)
    end

    it "counts an attachment it can't fetch instead of failing the export" do
      conv = create(:conversation, organization: org, domain: org.domains.first)
      msg = create(:message, conversation: conv)
      Attachment.create!(organization: org, message: msg, filename: "gone.pdf", storage_key: "att/gone.pdf")
      allow(storage).to receive(:download).with("att/gone.pdf").and_raise(Aws::S3::Errors::NoSuchKey.new(nil, "missing"))

      described_class.perform_now(export.id)
      expect(export.reload.status).to eq(DataExport::STATUS_READY)
      expect(export.counts).to include("messages" => 1, "attachments_missing" => 1)
    end
  end

  describe ".sweep!" do
    it "purges expired files and fails exports stuck in flight" do
      old = org.data_exports.create!(status: DataExport::STATUS_READY, storage_key: "k/old.zip", expires_at: 1.hour.ago)
      stuck = org.data_exports.create!(status: DataExport::STATUS_RUNNING)
      stuck.update_columns(updated_at: 7.hours.ago)
      allow(storage).to receive(:delete)

      DataExport.sweep!
      expect(storage).to have_received(:delete).with("k/old.zip")
      expect(old.reload).to have_attributes(status: DataExport::STATUS_EXPIRED, storage_key: nil)
      expect(stuck.reload.status).to eq(DataExport::STATUS_FAILED)
    end
  end
end
