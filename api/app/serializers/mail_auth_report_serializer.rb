class MailAuthReportSerializer < ::ApplicationSerializer
  attributes :kind, :reporter, :report_id, :domain, :total_count, :failure_count,
             :summary, :begin_at, :end_at, :created_at
end
