class SamlAssertion < ApplicationRecord
  key_prefix "smla"

  belongs_to :organization

  validates :assertion_id, presence: true, uniqueness: true

  # Atomically claim an assertion ID. Returns true the first time an ID is seen
  # and false on replay (the unique index rejects the duplicate insert). A blank
  # assertion_id is treated as a replay — a valid signed assertion always has one.
  def self.consume(assertion_id, organization)
    return false if assertion_id.blank?

    create!(assertion_id: assertion_id, organization: organization)
    true
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    false
  end
end
