# Parses a TLS-RPT aggregate report (RFC 8460): JSON, possibly gzipped, carried
# as an email attachment (application/tlsrpt+gzip / +json). Produces the
# attributes for one MailAuthReport row.
class TlsRptReportParser
  def initialize(json_text)
    @data = JSON.parse(json_text)
  end

  def attributes
    policies = Array(@data["policies"])
    success = policies.sum { |p| p.dig("summary", "total-successful-session-count").to_i }
    failure = policies.sum { |p| p.dig("summary", "total-failure-session-count").to_i }
    {
      kind: MailAuthReport::KIND_TLSRPT,
      reporter: @data["organization-name"],
      report_id: @data["report-id"],
      domain: policies.first&.dig("policy", "policy-domain"),
      begin_at: parse_time(@data.dig("date-range", "start-datetime")),
      end_at: parse_time(@data.dig("date-range", "end-datetime")),
      total_count: success + failure,
      failure_count: failure,
      summary: {
        "policies" => policies.map do |p|
          {
            "policy_type" => p.dig("policy", "policy-type"),
            "policy_domain" => p.dig("policy", "policy-domain"),
            "successful" => p.dig("summary", "total-successful-session-count").to_i,
            "failed" => p.dig("summary", "total-failure-session-count").to_i,
            "failure_details" => Array(p["failure-details"]).first(20)
          }
        end
      }
    }
  end

  private

  def parse_time(value)
    Time.iso8601(value) if value.present?
  rescue ArgumentError
    nil
  end
end
