class Template < ApplicationRecord
  key_prefix "tmpl"

  SCOPES = %w[personal shared].freeze
  SCOPE_PERSONAL = "personal".freeze
  SCOPE_SHARED = "shared".freeze

  belongs_to :organization
  belongs_to :membership, optional: true

  validates :name, presence: true
  validates :scope, inclusion: { in: SCOPES }
end
