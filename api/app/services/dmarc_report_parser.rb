# Parses a DMARC rua aggregate report (RFC 7489 appendix C): XML, usually
# inside a .zip or .gz attachment. Produces the attributes for one
# MailAuthReport row. A record counts as failed when the policy evaluation
# failed BOTH DKIM and SPF — that's mail that providers will quarantine/reject
# under our published policy.
class DmarcReportParser
  def initialize(xml_text)
    @doc = Nokogiri::XML(xml_text)
    @doc.remove_namespaces!
  end

  def attributes
    records = @doc.xpath("//record")
    total = records.sum { |r| r.at_xpath("row/count")&.text.to_i }
    failed_records = records.select do |r|
      r.at_xpath("row/policy_evaluated/dkim")&.text == "fail" &&
        r.at_xpath("row/policy_evaluated/spf")&.text == "fail"
    end
    failure = failed_records.sum { |r| r.at_xpath("row/count")&.text.to_i }

    {
      kind: MailAuthReport::KIND_DMARC,
      reporter: text("//report_metadata/org_name"),
      report_id: text("//report_metadata/report_id"),
      domain: text("//policy_published/domain"),
      begin_at: epoch(text("//report_metadata/date_range/begin")),
      end_at: epoch(text("//report_metadata/date_range/end")),
      total_count: total,
      failure_count: failure,
      summary: {
        "policy" => {
          "p" => text("//policy_published/p"),
          "adkim" => text("//policy_published/adkim"),
          "aspf" => text("//policy_published/aspf")
        }.compact,
        "failed_sources" => failed_records.first(20).map do |r|
          {
            "source_ip" => r.at_xpath("row/source_ip")&.text,
            "count" => r.at_xpath("row/count")&.text.to_i,
            "disposition" => r.at_xpath("row/policy_evaluated/disposition")&.text
          }
        end
      }
    }
  end

  private

  def text(xpath)
    @doc.at_xpath(xpath)&.text&.strip.presence
  end

  def epoch(value)
    Time.at(Integer(value)).utc if value.present?
  rescue ArgumentError, TypeError
    nil
  end
end
