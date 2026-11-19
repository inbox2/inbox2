# One-time re-triage after the five new built-in labels (docs/Triage.md
# "Upgrade re-triage"). Threads triaged before 2026-10-20 keep their old label —
# a bill sits as action_required, a newsletter as fyi — so each org's open,
# recent, machine-labelled threads with one of the overlapping labels go through
# ClassifySpaceJob once more (retriage: label/priority/space/next-action only,
# no summary, push, meeting detection or auto mode).
#
# Without an org id it sweeps: every org not yet done and on a plan with AI
# triage gets its own run (recurring.yml, hourly), so an org that upgrades later
# is picked up then. `organizations.lore_retriaged_at` marks an org done.
class LoreRetriageJob < ApplicationJob
  queue_as :default

  LABELS = [TriageLabel::FYI, TriageLabel::ACTION_REQUIRED, TriageLabel::SCHEDULING, TriageLabel::NEEDS_APPROVAL].freeze
  WINDOW = 90.days
  CAP = 500
  SPACING = 0.5 # seconds between queued jobs, so 500 threads don't hit Jev at once

  def perform(organization_id = nil, force = false)
    return sweep unless organization_id

    org = Organization.find_by(id: organization_id)
    return unless org && (force || org.lore_retriaged_at.nil?)
    return unless org.ai_triage_enabled? && SpaceClassifier.enabled?

    self.class.scope(org).each_with_index do |conv, i|
      ClassifySpaceJob.set(wait: (i * SPACING).seconds).perform_later(conv.id, false, true)
    end
    org.update_columns(lore_retriaged_at: Time.current)
  end

  # Open, last 90 days, labelled by Jev or a rule (never by hand), one of the
  # overlapping labels, newest inbound message readable server-side; newest first.
  def self.scope(org)
    sealed = Message.where("messages.conversation_id = conversations.id").where(is_inbound: true)
                    .order(created_at: :desc).limit(1).select(:encryption_scheme)
    org.conversations
       .where(status: Conversation::STATUS_OPEN, triage_label: LABELS)
       .where(updated_at: WINDOW.ago..)
       .where.not(triage_source: nil)
       .where.not("conversations.triage_source LIKE ?", "#{TriageLabel::SOURCE_MANUAL}%")
       .where("COALESCE((#{sealed.to_sql}), ?) NOT IN (?)", Message::ENCRYPTION_SCHEME_NONE, Message::SEALED_ENCRYPTION_SCHEMES)
       .order(updated_at: :desc, id: :desc)
       .limit(CAP)
  end

  private

  def sweep
    Organization.where(lore_retriaged_at: nil).find_each do |org|
      self.class.perform_later(org.id) if org.ai_triage_enabled?
    end
  end
end
