# One row per (person, sender, absence): the ledger that stops an out-of-office
# auto-reply becoming a mail loop (docs/Calendar.md).
#
# The unique index does the real work. Checking "have we replied?" and then
# inserting is not enough — the inbound consumer is at-least-once and more than
# one subscriber can run, so two deliveries of the same mail can both pass the
# check. Insert first, let the constraint arbitrate, and treat a duplicate-key
# error as "already answered".
#
# No `key_prefix`: this is internal bookkeeping and never crosses the API (E5
# only governs API-facing ids).
class OutOfOfficeReply < ApplicationRecord
  belongs_to :user
  belongs_to :organization

  validates :sender_address, presence: true
  validates :period_start, presence: true

  before_validation { self.sender_address = sender_address.to_s.downcase.strip.presence }

  # Records that `sender` has now been answered for this absence. Returns false
  # when they had already been answered, which is the caller's "don't send"
  # signal. Claim BEFORE sending: a duplicate row is harmless, a duplicate reply
  # is a loop.
  def self.claim(user:, organization:, sender:, period_start:)
    create!(user: user, organization: organization,
            sender_address: sender, period_start: period_start)
    true
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    false
  end
end
