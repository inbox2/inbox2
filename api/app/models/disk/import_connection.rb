module Disk
  # A read-only grant to an import source (build guide 9b), stored encrypted
  # and kept apart from mail channels and conferencing grants. reach member:
  # the member's own drive; reach org: an owner's or admin's org-wide grant.
  # tenant groups connections that share the source's rate budget, so a
  # throttle response holds every import for that tenant (spec F10).
  class ImportConnection < ApplicationRecord
    REACH_MEMBER = "member".freeze
    REACH_ORG = "org".freeze
    REACHES = [REACH_MEMBER, REACH_ORG].freeze

    belongs_to :organization
    belongs_to :membership

    encrypts :refresh_token, :access_token

    validates :provider, inclusion: { in: Disk::ImportSource::PROVIDERS }
    validates :reach, inclusion: { in: REACHES }

    def org? = reach == REACH_ORG
    def tenant_key = tenant.presence || "connection:#{id}"

    # Until when this connection's tenant is held by a throttle response.
    def waiting_until
      at = self.class.where(provider: provider, tenant: tenant_key).maximum(:throttled_until)
      at if at&.future?
    end

    def throttle!(seconds)
      self.class.where(provider: provider, tenant: tenant_key).or(self.class.where(id: id))
        .update_all(throttled_until: seconds.seconds.from_now)
    end

    def access_token_fresh? = access_token.present? && access_expires_at&.>(1.minute.from_now)

    def store_access!(token, expires_in)
      update!(access_token: token, access_expires_at: (expires_in || 3600).to_i.seconds.from_now)
    end
  end
end
