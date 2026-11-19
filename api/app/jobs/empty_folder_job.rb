# "Empty Trash" / "Empty Spam" for a big folder (conversations#empty hands off
# above EMPTY_FOLDER_SYNC_LIMIT threads). Destroys the member's visible slice of
# the folder in batches so no request or transaction holds thousands of rows,
# and clears the mobile notifications per batch like the inline path does.
class EmptyFolderJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 200

  def perform(organization_id, membership_id, status)
    organization = Organization.find_by(id: organization_id)
    return unless organization && Conversation::EMPTYABLE_STATUSES.include?(status)

    membership = membership_id && organization.memberships.find_by(id: membership_id)
    scope = membership ? organization.conversations.visible_to(membership) : organization.conversations.not_private
    scope = scope.where(status: status)

    loop do
      batch = scope.order(:id).limit(BATCH_SIZE).to_a
      break if batch.empty?

      keys = batch.map(&:key)
      batch.each(&:destroy!)
      MobilePushSender.remove_for_org(organization, keys)
    rescue => e
      Rails.logger.warn("[EmptyFolderJob] #{organization.key}/#{status}: #{e.class}: #{e.message}")
      raise
    end
  end
end
