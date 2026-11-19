# One source mailbox (a Google Workspace or Microsoft 365 user) imported into
# its owner's private MX history (docs/plans/mail-import.md). The same row is
# re-run for the catch-up after the MX flip: once done, cursor holds the
# source's change token (Gmail historyId, Graph delta links), so a re-run reads
# only what arrived since. States and pause reasons match Disk::Import, whose
# importer base this reuses for tokens, throttling and stops.
class MailImport < ApplicationRecord
  key_prefix "mim"

  STATE_QUEUED = Disk::Import::STATE_QUEUED
  STATE_RUNNING = Disk::Import::STATE_RUNNING
  STATE_PAUSED = Disk::Import::STATE_PAUSED
  STATE_DONE = Disk::Import::STATE_DONE
  STATE_CANCELLED = Disk::Import::STATE_CANCELLED
  STATES = [STATE_QUEUED, STATE_RUNNING, STATE_PAUSED, STATE_DONE, STATE_CANCELLED].freeze

  PAUSE_AUTHORIZATION = Disk::Import::PAUSE_AUTHORIZATION
  PAUSE_ERROR = Disk::Import::PAUSE_ERROR
  PAUSE_REASONS = [PAUSE_AUTHORIZATION, PAUSE_ERROR].freeze

  PROVIDERS = [OauthProvider::GOOGLE, OauthProvider::MICROSOFT].freeze # pulled through the source's API
  TAKEOUT = "takeout".freeze # an .mbox (Google Takeout) from Disk or an operator's rake task (MailImporter::Takeout)
  STALE_AFTER = Disk::Import::STALE_AFTER

  belongs_to :organization
  belongs_to :membership
  belongs_to :owner, class_name: "Membership", foreign_key: :owner_membership_id
  belongs_to :domain
  belongs_to :connection, class_name: "Disk::ImportConnection", optional: true
  # The .mbox on Disk a person picked in Settings; nil for the operator's rake task.
  belongs_to :source_node, class_name: "Disk::Node", optional: true
  has_many :threads, class_name: "MailImportThread", dependent: :delete_all

  validates :provider, inclusion: { in: PROVIDERS + [TAKEOUT] }
  validates :state, inclusion: { in: STATES }
  validates :pause_reason, inclusion: { in: PAUSE_REASONS }, allow_nil: true
  validates :source_email, presence: true

  STATES.each { |s| define_method("#{s}?") { state == s } }

  # done: the catch-up re-run after the MX flip.
  # A Takeout import re-reads its Disk file; without one only the rake task, given the file, resumes it.
  def resumable?
    return false if provider == TAKEOUT && source_node_id.nil?

    paused? || queued? || done? || cancelled? || (running? && updated_at < STALE_AFTER.ago)
  end

  # Disk::Importer reads these; a mail import has no Disk space.
  def space_kind = nil
  def actor = membership
end
