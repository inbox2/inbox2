module Api
  module V1
    module Saas
      class OrganizationsController < BaseController
        before_action :set_organization, except: %i[index create]

        # GET /api/v1/saas/organizations?q=&page=&per_page=
        def index
          scope = Organization.teams # personal workspaces hold a C:\ and nothing else
          if (q = params[:q]).present?
            like = "%#{q.strip.downcase}%"
            scope = scope.left_joins(:domains)
              .where("LOWER(organizations.name) LIKE :q OR LOWER(organizations.slug) LIKE :q OR LOWER(domains.name) LIKE :q", q: like)
              .distinct
          end
          # Preload the per-row associations the serializer maps over. (plan /
          # subscription / mailbox_count remain method-derived; low traffic.)
          scope = scope.includes(:owner, :domains)
          records, meta = paginate(scope.order(created_at: :desc), default_per_page: 25, max_per_page: 100)
          render json: { organizations: records.map { |o| serialize(o) }, meta: meta }
        end

        # GET /api/v1/saas/organizations/:id
        def show
          render json: { organization: serialize(@organization) }
        end

        # POST /api/v1/saas/organizations
        def create
          owner = User.find_by(key: params[:owner_id])
          return render_error("owner_id must reference an existing user", status: :unprocessable_content) unless owner

          domain_name = params[:domain].to_s.downcase.strip
          return render_error("domain is required", status: :unprocessable_content) if domain_name.blank?
          return render_error("Domain already in use", status: :unprocessable_content) if Domain.exists?(name: domain_name)

          begin
            org = Organization.provision!(owner: owner, domain_name: domain_name, **create_params.to_h.symbolize_keys)
          rescue ActiveRecord::RecordInvalid => e
            return render_error(e.record.errors.full_messages, status: :unprocessable_content)
          end

          audit!(::SaasAuditLog::ACTION_ORG_CREATE, target: org)
          render json: { organization: serialize(org) }, status: :created
        end

        # PATCH /api/v1/saas/organizations/:id
        def update
          if @organization.update(update_params)
            audit!(::SaasAuditLog::ACTION_ORG_UPDATE, target: @organization, metadata: { fields: update_params.keys })
            render json: { organization: serialize(@organization) }
          else
            render_error(@organization.errors.full_messages, status: :unprocessable_content)
          end
        end

        # POST /api/v1/saas/organizations/:id/suspend
        def suspend
          @organization.suspend!(params[:reason])
          audit!(::SaasAuditLog::ACTION_ORG_SUSPEND, target: @organization, metadata: { reason: params[:reason] })
          render json: { organization: serialize(@organization) }
        end

        # POST /api/v1/saas/organizations/:id/unsuspend
        def unsuspend
          @organization.unsuspend!
          audit!(::SaasAuditLog::ACTION_ORG_UNSUSPEND, target: @organization)
          render json: { organization: serialize(@organization) }
        end

        # DELETE /api/v1/saas/organizations/:id/wipe — GDPR hard wipe.
        # Destroys the org and every dependent record (dependent: :destroy cascade).
        # Irreversible. The audit row keeps an identity snapshot since the org is gone.
        def wipe
          snapshot = { key: @organization.key, domain: @organization.default_domain&.name, name: @organization.name }
          @organization.destroy!
          ::SaasAuditLog.record!(
            admin: current_admin, action: ::SaasAuditLog::ACTION_ORG_WIPE,
            ip: client_ip, metadata: snapshot
          )
          head :no_content
        end

        # GET /api/v1/saas/organizations/:id/usage
        def usage
          render json: { usage: ::Saas::OrganizationUsageSerializer.new(@organization).to_h }
        end

        # POST /api/v1/saas/organizations/:id/plan — set or clear the per-org
        # plan override. plan: "plan_xxx" | "Free" | "Paid" | null/"inherit".
        def plan
          if !params.key?(:plan) || params[:plan].nil? || params[:plan].to_s == "inherit"
            @organization.update!(plan: nil)
          else
            target = params[:plan].to_s
            found = target.start_with?("plan_") ? Plan.find_by(key: target) : Plan.find_by(name: target)
            return render_error("Unknown plan", status: :unprocessable_content) unless found

            @organization.update!(plan: found)
          end

          audit!(::SaasAuditLog::ACTION_ORG_PLAN, target: @organization, metadata: { plan: @organization.plan&.name })
          render json: { organization: serialize(@organization) }
        end

        # POST /api/v1/saas/organizations/:id/mailbox_limit — set the cap.
        # preset: "single"|"team"|"unlimited", OR mailbox_limit: <int>|null (null = inherit plan).
        def mailbox_limit
          value = resolve_mailbox_limit
          return if performed?

          @organization.update!(mailbox_limit: value)
          audit!(::SaasAuditLog::ACTION_ORG_MAILBOX_LIMIT, target: @organization, metadata: { mailbox_limit: value })
          render json: { organization: serialize(@organization) }
        end

        # POST /api/v1/saas/organizations/:id/disk_quota { quota_gb: <int>|null }
        # Overrides the org's pooled Disk quota; null goes back to the plan's.
        def disk_quota
          raw = params[:quota_gb]
          value = raw.nil? || raw.to_s.strip.empty? ? nil : Integer(raw.to_s, exception: false)
          if !raw.nil? && !raw.to_s.strip.empty? && (value.nil? || value.negative?)
            return render_error("quota_gb must be a whole number of GB, or null", status: :unprocessable_content)
          end

          @organization.update!(disk_quota_override_gb: value)
          audit!(::SaasAuditLog::ACTION_ORG_DISK_QUOTA, target: @organization, metadata: { quota_gb: value })
          render json: { usage: ::Saas::OrganizationUsageSerializer.new(@organization).to_h }
        end

        private

        def set_organization
          @organization = Organization.find_by!(key: params[:id])
        end

        def serialize(org)
          ::Saas::OrganizationSerializer.new(org).to_h
        end

        def create_params
          params.permit(:name, :slug, :timezone, :language, :data_retention_days, :icon_url, :logo_url)
        end

        def update_params
          params.permit(:name, :slug, :timezone, :language, :data_retention_days, :icon_url, :logo_url)
        end

        def resolve_mailbox_limit
          if (preset = params[:preset]).present?
            unless Organization::MAILBOX_LIMIT_PRESETS.key?(preset)
              render_error("Unknown preset (use single|team|unlimited)", status: :unprocessable_content)
              return nil
            end
            return Organization::MAILBOX_LIMIT_PRESETS[preset]
          end

          if params.key?(:mailbox_limit)
            raw = params[:mailbox_limit]
            return nil if raw.nil? || raw.to_s.strip.empty? # clear → inherit plan
            return raw.to_i
          end

          render_error("Provide preset or mailbox_limit", status: :unprocessable_content)
          nil
        end
      end
    end
  end
end
