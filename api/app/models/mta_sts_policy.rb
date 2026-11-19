class MtaStsPolicy < ApplicationRecord
  key_prefix "sts"

  MODES = %w[testing enforce none].freeze
  MODE_TESTING = "testing".freeze
  MODE_ENFORCE = "enforce".freeze
  MODE_NONE = "none".freeze

  belongs_to :domain

  validates :mode, inclusion: { in: MODES }
  validates :max_age, numericality: { greater_than: 0 }

  def policy_text
    lines = ["version: STSv1", "mode: #{mode}", "max_age: #{max_age}"]
    mx_list.each { |mx| lines << "mx: #{mx}" }
    lines.join("\n")
  end

  def dns_record
    "_mta-sts.#{domain.name} IN TXT \"v=STSv1; id=#{updated_at.to_i}\""
  end

  private

  def mx_list
    (mx_hosts || "").split("\n").map(&:strip).reject(&:blank?)
  end
end
