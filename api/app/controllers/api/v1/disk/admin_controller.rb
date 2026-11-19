module Api
  module V1
    module Disk
      # The console's Disk page (spec F11): usage, every public link, settings
      # and the org export. Owners and admins only. A member's C:\ is their own
      # (2026-10-07), so nothing here touches or hands over C:\ drives.
      class AdminController < BaseController
        before_action :require_admin!

        # GET /admin/usage
        def usage
          bytes = byte_rows
          members = current_organization.memberships.where(status: Membership::STATUS_ACTIVE, member_type: Membership::TYPE_HUMAN)
            .or(current_organization.memberships.where(id: bytes.keys.filter_map(&:first)))
            .includes(:user).order(:created_at).to_a
          shares = ::Disk::Share.where(organization_id: current_organization.id).order(:name).to_a
          counts = ::Disk::ShareMembership.where(share_id: shares.map(&:id)).group(:share_id).count
          row = ::Disk::UsageSerializer::Row
          usage = ::Disk::UsageSerializer::Usage.new(
            organization: current_organization, quota: ::Disk::Quota.new(current_organization),
            members: members.map { |m| row.new(membership: m, bytes: bytes.sum { |(mid, _), b| mid == m.id ? b : 0 }) },
            shares: shares.map { |s| row.new(share: s, bytes: bytes.sum { |(_, sid), b| sid == s.id ? b : 0 }, member_count: counts.fetch(s.id, 0)) }
          )
          render json: { usage: ::Disk::UsageSerializer.new(usage).to_h }
        end

        # GET /admin/links?cursor= — every link not yet revoked, expired ones included.
        def links
          rel = ::Disk::Link.where(organization_id: current_organization.id).active
            .includes(:node, created_by: :user).order(created_at: :desc, id: :desc)
          rows, next_cursor = paginate_cursor(rel)
          paths = ::Disk::Node.paths_for(rows.map(&:node))
          render json: { links: ::Disk::AdminLinkSerializer.new(rows, params: { paths: paths }).to_h,
                         next_cursor: next_cursor }
        end

        # DELETE /admin/links/:id — stops resolving at once, wherever the link is.
        def revoke_link
          link = ::Disk::Link.where(organization_id: current_organization.id).find_by!(key: params[:id].to_s)
          unless link.revoked?
            link.update!(revoked_at: Time.current)
            ::Disk::Event.record!(::Disk::Event::ACTION_LINK_REVOKED, actor: membership, node: link.node, link: link)
          end
          head :no_content
        end

        # GET /admin/events?share=&member=&type=&from=&to=&tz=&cursor= — the org's
        # activity, newest first (spec F11). `member` is the actor; `from` and
        # `to` are ISO dates, both inclusive, in `tz` (IANA, default UTC).
        # Preview failures are metrics, not activity.
        def events
          rel = ::Disk::Event.where(organization_id: current_organization.id)
            .where.not(action: ::Disk::Event::ACTION_PREVIEW_FAILED)
            .includes(:node, :share, :link, :actor_agent, actor: %i[user agents]).order(created_at: :desc, id: :desc)
          if params[:share].present?
            rel = rel.where(share_id: ::Disk::Share.where(organization_id: current_organization.id).find_by!(key: params[:share].to_s).id)
          end
          rel = rel.where(actor_membership_id: current_organization.memberships.find_by!(key: params[:member].to_s).id) if params[:member].present?
          if params[:type].present?
            raise ::Disk::Refused, "type must be one of the event actions" unless ::Disk::Event::ACTIONS.include?(params[:type])

            rel = rel.where(action: params[:type])
          end
          rel = rel.where(created_at: event_date(:from).beginning_of_day..) if params[:from].present?
          rel = rel.where(created_at: ..event_date(:to).end_of_day) if params[:to].present?
          rows, next_cursor = paginate_cursor(rel)
          render json: { events: ::Disk::AdminEventSerializer.new(rows).to_h, next_cursor: next_cursor }
        end

        # PUT /admin/settings { links_enabled } — the quota is SaaS ops' to override.
        def settings
          raise ActionController::ParameterMissing, :links_enabled unless params.key?(:links_enabled)

          current_organization.update!(disk_links_enabled: ActiveModel::Type::Boolean.new.cast(params[:links_enabled]))
          render json: { settings: ::Disk::SettingsSerializer.new(current_organization).to_h }
        end

        # GET /admin/export?cursor= — the manifest on the first page, then
        # entries with presigned URLs page by page (Disk::Export).
        def export
          export = ::Disk::Export.new(current_organization)
          entries, next_cursor = export.entries(params[:cursor])
          page = ::Disk::ExportSerializer::Page.new(manifest: params[:cursor].blank? ? export.manifest : nil,
                                                    entries: entries, next_cursor: next_cursor)
          render json: { export: ::Disk::ExportSerializer.new(page).to_h }
        end

        private

        def event_date(key)
          zone = ActiveSupport::TimeZone[params[:tz].presence || "UTC"] || raise(::Disk::Refused, "Unknown time zone")
          zone.parse(Date.iso8601(params[key].to_s).iso8601)
        rescue Date::Error
          raise ::Disk::Refused, "#{key} must be a date like 2026-10-04"
        end


        # { [custodian membership id, share id] => bytes } over every version.
        def byte_rows
          ::Disk::Version.joins(:node).where(organization_id: current_organization.id)
            .group("disk_nodes.custodian_membership_id", "disk_nodes.share_id").sum("disk_versions.size_bytes")
        end
      end
    end
  end
end
