module Api
  module V1
    module Disk
      class DrivesController < BaseController
        # GET /orgs/:org_id/disk — C:\ root (the person's own, the same from every
        # team), its personal quota, this team's drive letter, visible shares,
        # the team's quota meter and settings.
        def show
          shares = ::Disk::Access.visible_shares(membership).live.includes(:root_node).order(:name).to_a
          render json: {
            c_drive: node_json(c_root),
            c_quota: ::Disk::QuotaSerializer.new(::Disk::Quota.new(current_user.personal_organization)).to_h,
            drive_letter: membership.drive_letter,
            shares: ::Disk::ShareSerializer.new(shares, params: { member_counts: member_counts(shares) }).to_h,
            quota: ::Disk::QuotaSerializer.new(::Disk::Quota.new(current_organization)).to_h,
            settings: ::Disk::SettingsSerializer.new(current_organization).to_h
          }
        end

        private

        def c_root = ::Disk::Node.c_root_for(current_user)

        def member_counts(shares)
          ::Disk::ShareMembership.where(share_id: shares.map(&:id)).group(:share_id).count
        end
      end
    end
  end
end
