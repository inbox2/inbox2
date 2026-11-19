module Api
  module V1
    module Disk
      # Shares on D:\. Owners and admins create, delete, restore and purge;
      # a share's managers rename, recolour and archive it.
      class SharesController < BaseController
        # GET /shares — visible shares; admins pass trashed=true for the admin trash.
        def index
          shares = ::Disk::Access.visible_shares(membership).includes(:root_node, :domain).order(:name)
          shares = admin? && params[:trashed].to_s == "true" ? shares.where.not(trashed_at: nil) : shares.live
          render_shares(shares.to_a)
        end

        # POST /shares { name, icon, color, openness, org_role, domain_id } or, sealed (build
        # guide 6.2), { name, icon, color, sealed: true, sealed_key }: assigned
        # only, the creator its first manager and key holder at epoch 1.
        def create
          require_admin!
          return create_sealed if ActiveModel::Type::Boolean.new.cast(params[:sealed])

          share = ::Disk::Share.create_with_root!(organization: current_organization, **share_params.to_h.symbolize_keys)
          ::Disk::Event.record!(::Disk::Event::ACTION_SHARE_CREATED, actor: membership, share: share, name: share.name)
          render json: { share: share_json(share) }, status: :created
        end

        # PATCH /shares/:id
        def update
          share = find_share!
          ops.require_role!(share.root_node, ::Disk::ROLE_MANAGE)
          share.assign_attributes(share_params)
          raise ::Disk::Refused, "A sealed share is open only to its members" if share.root_node.sealed? && share.open_to_org?

          share.archived_at = params[:archived].to_s == "true" ? (share.archived_at || Time.current) : nil if params.key?(:archived)
          share.save!
          ::Disk::Event.record!(::Disk::Event::ACTION_SHARE_UPDATED, actor: membership, share: share,
                                                                     changes: share.saved_changes.keys - %w[updated_at])
          render json: { share: share_json(share) }
        end

        # DELETE /shares/:id — needs the share's name typed back; 30 days in the admin trash.
        def destroy
          require_admin!
          share = find_share!
          raise ::Disk::Refused, "Type the share's name to delete it" unless params[:confirm_name].to_s == share.name
          raise ::Disk::Refused, "This share is already in the trash" if share.trashed?

          now = Time.current
          ::Disk::Share.transaction do
            share.update!(trashed_at: now, trashed_by: membership, purge_at: now + ::Disk::Share::TRASH_DAYS.days)
            # Revoked, not just hidden: restoring the share does not bring its links back.
            ::Disk::Link.active.where(node_id: share.nodes.select(:id)).update_all(revoked_at: now)
          end
          ::Disk::Event.record!(::Disk::Event::ACTION_SHARE_TRASHED, actor: membership, share: share, name: share.name)
          render json: { share: share_json(share) }
        end

        # POST /shares/:id/restore
        def restore
          require_admin!
          share = find_share!
          raise ::Disk::Refused, "This share is not in the trash" unless share.trashed?

          share.update!(trashed_at: nil, trashed_by: nil, purge_at: nil)
          ::Disk::Event.record!(::Disk::Event::ACTION_SHARE_RESTORED, actor: membership, share: share)
          render json: { share: share_json(share) }
        end

        # DELETE /shares/:id/purge
        def purge
          require_admin!
          share = find_share!
          raise ::Disk::Refused, "Only a share in the trash can be deleted forever" unless share.trashed?

          share.purge!
          head :no_content
        end

        # POST /shares/templates { names: ["Marketing", ...] } — first-run shares.
        def templates
          require_admin!
          names = Array(params.require(:names)).map(&:to_s)
          domain = team
          picked = ::Disk::Share::TEMPLATES.select { |t| names.include?(t[:name]) }
          raise ::Disk::Refused, "Unknown template" unless picked.size == names.uniq.size

          existing = current_organization.disk_shares.live.where(domain: domain).pluck(:name).map(&:downcase)
          shares = ::Disk::Share.transaction do
            picked.reject { |t| existing.include?(t[:name].downcase) }.map do |t|
              ::Disk::Share.create_with_root!(organization: current_organization, domain: domain, **t)
            end
          end
          shares.each do |s|
            ::Disk::Event.record!(::Disk::Event::ACTION_SHARE_CREATED, actor: membership, share: s, name: s.name)
          end
          render json: { shares: ::Disk::ShareSerializer.new(shares).to_h }, status: :created
        end

        private

        def create_sealed
          ::Disk::Sealing.entitled!(current_organization)
          attrs = share_params.to_h.symbolize_keys
          raise ::Disk::Refused, "A sealed share is open only to its members" if attrs[:openness] == ::Disk::Share::OPENNESS_ORG

          share = ::Disk::Share.transaction do
            s = ::Disk::Share.create_with_root!(organization: current_organization, **attrs.merge(openness: ::Disk::Share::OPENNESS_ASSIGNED))
            ::Disk::ShareMembership.create!(organization: current_organization, share: s, membership: membership,
                                            role: ::Disk::ROLE_MANAGE)
            ::Disk::Sealing.open_scope!(s.root_node, membership, params.require(:sealed_key))
            s
          end
          ::Disk::Event.record!(::Disk::Event::ACTION_SHARE_CREATED, actor: membership, share: share, name: share.name, sealed: true)
          render json: { share: share_json(share) }, status: :created
        end

        def find_share! = ::Disk::Share.find_by_ref!(::Disk::Access.visible_shares(membership), params[:id])

        def share_params
          attrs = params.permit(:name, :icon, :color, :openness, :org_role)
          params.key?(:domain_id) ? attrs.merge(domain: team) : attrs
        end

        # The team a share belongs to: domain_id (dom_...) among this org's domains, blank for the whole org.
        def team
          ref = params[:domain_id].presence
          ref && current_organization.domains.find_by!(key: ref.to_s)
        end

        def share_json(share)
          ::Disk::ShareSerializer.new(share, params: { member_counts: member_counts([share]) }).to_h
        end

        def render_shares(shares)
          render json: { shares: ::Disk::ShareSerializer.new(shares, params: { member_counts: member_counts(shares) }).to_h }
        end

        def member_counts(shares)
          ::Disk::ShareMembership.where(share_id: shares.map(&:id)).group(:share_id).count
        end
      end
    end
  end
end
