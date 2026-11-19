class Rule < ApplicationRecord
  key_prefix "rule"

  # Field names match the Rust core's MessageFields exactly (the rules UI and the
  # local-channel matcher both use `from`/`to`).
  FIELDS = %w[from to subject body has_attachment].freeze
  FIELD_FROM = "from".freeze
  FIELD_TO = "to".freeze
  FIELD_SUBJECT = "subject".freeze
  FIELD_BODY = "body".freeze
  FIELD_HAS_ATTACHMENT = "has_attachment".freeze

  OPERATORS = %w[equals contains starts_with ends_with].freeze
  OPERATOR_EQUALS = "equals".freeze
  OPERATOR_CONTAINS = "contains".freeze
  OPERATOR_STARTS_WITH = "starts_with".freeze
  OPERATOR_ENDS_WITH = "ends_with".freeze
  # Boolean operators, valid only for the `has_attachment` field.
  OPERATOR_IS_TRUE = "is_true".freeze
  OPERATOR_IS_FALSE = "is_false".freeze

  ACTION_TYPES = %w[add_tag set_status assign grant_access webhook].freeze
  ACTION_ADD_TAG = "add_tag".freeze
  ACTION_SET_STATUS = "set_status".freeze
  ACTION_ASSIGN = "assign".freeze
  ACTION_GRANT_ACCESS = "grant_access".freeze
  ACTION_WEBHOOK = "webhook".freeze

  belongs_to :organization
  has_many :rule_logs, dependent: :destroy

  validates :name, presence: true
  validates :conditions, presence: true
  validate :actions_or_branches_present

  scope :ordered, -> { order(position: :asc) }

  private

  def actions_or_branches_present
    if actions.blank? && branches.blank? && else_actions.blank?
      errors.add(:actions, "or branches must be present")
    end
  end
end
