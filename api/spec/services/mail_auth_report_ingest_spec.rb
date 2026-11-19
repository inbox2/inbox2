require "rails_helper"
require "mail"

# TODO 46.10 — TLS-RPT (RFC 8460) + DMARC rua (RFC 7489) aggregate ingestion
# via InboundReportRouter → MailAuthReport rows.
RSpec.describe "Mail auth report ingestion" do
  let(:owner) { create(:user, username: "marowner") }
  let(:org) { create(:organization, owner: owner, domain: "team.com") }

  let(:tlsrpt_json) do
    {
      "organization-name" => "Google Inc.",
      "date-range" => { "start-datetime" => "2026-07-09T00:00:00Z", "end-datetime" => "2026-07-10T00:00:00Z" },
      "report-id" => "2026-07-09-team.com",
      "policies" => [
        {
          "policy" => { "policy-type" => "sts", "policy-domain" => "team.com" },
          "summary" => { "total-successful-session-count" => 42, "total-failure-session-count" => 3 },
          "failure-details" => [{ "result-type" => "certificate-expired", "failed-session-count" => 3 }]
        }
      ]
    }.to_json
  end

  let(:dmarc_xml) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <feedback>
        <report_metadata>
          <org_name>google.com</org_name>
          <report_id>1234567890</report_id>
          <date_range><begin>1783900800</begin><end>1783987200</end></date_range>
        </report_metadata>
        <policy_published><domain>team.com</domain><p>quarantine</p></policy_published>
        <record>
          <row>
            <source_ip>203.0.113.7</source_ip><count>10</count>
            <policy_evaluated><disposition>none</disposition><dkim>pass</dkim><spf>pass</spf></policy_evaluated>
          </row>
        </record>
        <record>
          <row>
            <source_ip>198.51.100.9</source_ip><count>4</count>
            <policy_evaluated><disposition>quarantine</disposition><dkim>fail</dkim><spf>fail</spf></policy_evaluated>
          </row>
        </record>
      </feedback>
    XML
  end

  def route(raw, hint: nil)
    InboundReportRouter.new(org, raw, content_type_hint: hint).route
  end

  describe "TLS-RPT" do
    it "stores a report from a multipart/report; report-type=tlsrpt message" do
      mail = Mail.new do
        from "noreply-smtp-tls-reporting@google.com"
        to "tlsrpt@team.com"
        subject "Report Domain: team.com Submitter: google.com"
        content_type 'multipart/report; report-type="tlsrpt"; boundary="b1"'
      end
      part = Mail::Part.new
      part.content_type = "application/tlsrpt+json"
      part.body = tlsrpt_json
      mail.add_part(part)

      expect { expect(route(mail.to_s, hint: mail.content_type)).to eq(:tlsrpt) }
        .to change(MailAuthReport, :count).by(1)

      report = MailAuthReport.last
      expect(report.kind).to eq(MailAuthReport::KIND_TLSRPT)
      expect(report.reporter).to eq("Google Inc.")
      expect(report.domain).to eq("team.com")
      expect(report.total_count).to eq(45)
      expect(report.failure_count).to eq(3)
      expect(report.summary["policies"].first["failure_details"].first["result-type"]).to eq("certificate-expired")
    end

    it "handles a gzipped payload" do
      gz = StringIO.new
      writer = Zlib::GzipWriter.new(gz)
      writer.write(tlsrpt_json)
      writer.close

      mail = Mail.new do
        content_type 'multipart/report; report-type="tlsrpt"; boundary="b2"'
      end
      part = Mail::Part.new
      part.content_type = "application/tlsrpt+gzip"
      part.content_transfer_encoding = "base64"
      part.body = Base64.encode64(gz.string)
      mail.add_part(part)

      expect(route(mail.to_s, hint: mail.content_type)).to eq(:tlsrpt)
      expect(MailAuthReport.last.total_count).to eq(45)
    end
  end

  describe "DMARC rua" do
    def zip_bytes(name, content)
      buffer = Zip::OutputStream.write_buffer do |out|
        out.put_next_entry(name)
        out.write(content)
      end
      buffer.string
    end

    it "stores a report from a .zip attachment and counts dual-fail rows" do
      mail = Mail.new do
        from "noreply-dmarc-support@google.com"
        to "dmarc@inbox2.com"
        subject "Report domain: team.com Submitter: google.com"
      end
      mail.add_file(filename: "google.com!team.com!1783900800!1783987200.zip",
                    content: zip_bytes("report.xml", dmarc_xml))

      expect { expect(route(mail.to_s)).to eq(:dmarc) }.to change(MailAuthReport, :count).by(1)

      report = MailAuthReport.last
      expect(report.kind).to eq(MailAuthReport::KIND_DMARC)
      expect(report.reporter).to eq("google.com")
      expect(report.domain).to eq("team.com")
      expect(report.total_count).to eq(14)
      expect(report.failure_count).to eq(4)
      expect(report.summary["failed_sources"].first["source_ip"]).to eq("198.51.100.9")
    end

    it "dedupes a resent report by (kind, reporter, report_id)" do
      mail = Mail.new
      mail.add_file(filename: "r.zip", content: zip_bytes("report.xml", dmarc_xml))
      route(mail.to_s)
      expect { route(mail.to_s) }.not_to change(MailAuthReport, :count)
    end

    it "ignores ordinary mail with a zip attachment" do
      mail = Mail.new { subject "Holiday photos" }
      mail.add_file(filename: "photos.zip", content: zip_bytes("readme.txt", "not a report"))
      expect(route(mail.to_s)).to be_nil
    end
  end
end
