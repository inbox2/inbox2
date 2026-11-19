module Api
  module V1
    module Disk
      # Identity public keys of org members, for sealing a scope key to them
      # (build guide 7). Members missing from the org are left out; a member
      # with no identity key comes back with public_key null.
      class KeysController < BaseController
        MAX_IDS = 200

        # GET /keys/members?ids=mem_a,mem_b
        def members
          ids = params.require(:ids).to_s.split(",").map(&:strip).reject(&:empty?).uniq
          raise ::Disk::Refused, "Ask for 1 to #{MAX_IDS} members at a time" if ids.empty? || ids.size > MAX_IDS

          # This team's members, plus the caller's own personal membership (the custodian of their C:\).
          rows = Membership.where(key: ids).where(organization_id: current_organization.id)
            .or(Membership.where(key: ids, id: membership.personal_membership_id)).order(:id)
          render json: { members: ::Disk::MemberKeySerializer.new(rows).to_h }
        end
      end
    end
  end
end
