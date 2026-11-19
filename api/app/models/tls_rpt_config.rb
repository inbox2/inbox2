class TlsRptConfig < ApplicationRecord
  key_prefix "tlsrpt"

  belongs_to :domain

  validates :reporting_email, presence: true

  def dns_record
    "_smtp._tls.#{domain.name} IN TXT \"v=TLSRPTv1; rua=mailto:#{reporting_email}\""
  end
end
