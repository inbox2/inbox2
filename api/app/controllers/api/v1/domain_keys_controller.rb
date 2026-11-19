module Api
  module V1
    # E2EE key provisioning for a domain (docs/E2EE.md Phase B). The server
    # stores opaque blobs only: the domain public key, and the domain secret
    # sealed per-membership to each member's identity public key. No endpoint
    # here (or anywhere) returns a usable secret key.
    class DomainKeysController < BaseController
      before_action :require_organization!
      before_action :set_domain, except: :mine

      # Every sealing key this member can open, including a domain outside their
      # scope where a thread was assigned to them. Current key versions only.
      def mine
        grants = current_active_membership!.domain_key_grants.includes(domain_key: :domain)
                                           .select { |g| g.domain_key == g.domain_key.domain.current_e2ee_key }
        render json: { grants: grants.map { |g| DomainKeyGrantSerializer.new(g).to_h } }
      end

      # E2EE state for the domain: flags, current public key, the caller's own
      # sealed grant, and the member directory (identity PUBLIC keys only) the
      # client needs to mint keys / issue grants.
      def show
        current_key = @domain.current_e2ee_key

        render json: {
          e2ee: {
            enabled: @domain.e2ee_enabled,
            notification_preview: @domain.e2ee_notification_preview,
            entitled: current_organization.e2ee_entitled?,
            available: E2ee.available?,
            effective: E2ee.effective?(@domain) && current_key.present?,
            current_key: current_key && DomainKeySerializer.new(current_key).to_h,
            my_grant: my_grant_payload(current_key),
            members: member_directory(current_key)
          }
        }
      end

      # Mint the next key version with its member grants, atomically retiring the
      # previous one. The caller generated the keypair client-side and must grant
      # itself — a minter who can't open the new key would brick the domain.
      def create
        return unless require_admin!

        grants = Array(params[:grants])
        unless grants.any? { |g| g[:membership_id] == current_membership.key }
          return render json: ErrorSerializer.serialize("grants must include the minting member", status: 422), status: :unprocessable_content
        end

        memberships = grant_memberships(grants)
        return if performed? # grant_memberships rendered an error

        domain_key = nil
        ActiveRecord::Base.transaction do
          @domain.domain_keys.active.update_all(retired_at: Time.current)
          domain_key = @domain.domain_keys.create!(
            version: (@domain.domain_keys.maximum(:version) || 0) + 1,
            public_key: params[:public_key].to_s
          )
          grants.each do |g|
            domain_key.grants.create!(
              membership: memberships.fetch(g[:membership_id]),
              sealed_secret_key: g[:sealed_secret_key].to_s
            )
          end
        end

        render json: { domain_key: DomainKeySerializer.new(domain_key).to_h }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: ErrorSerializer.serialize(e.record.errors.full_messages, status: 422), status: :unprocessable_content
      end

      # (Re-)issue a grant on the CURRENT key to one member — the recovery path
      # for a member with a new identity key, or a late add. Only a member who
      # already holds a grant can have unwrapped the secret to re-seal it.
      def create_grant
        current_key = @domain.current_e2ee_key
        unless current_key
          return render json: ErrorSerializer.serialize("Domain has no e2ee key", status: 422), status: :unprocessable_content
        end
        unless current_key.grants.exists?(membership: current_membership)
          return render json: ErrorSerializer.serialize("Only a member holding a grant can issue grants", status: 403), status: :forbidden
        end

        membership = active_memberships.find_by(key: params[:membership_id].to_s)
        unless membership
          return render json: ErrorSerializer.serialize("Membership not found", status: 404), status: :not_found
        end

        grant = current_key.grants.find_or_initialize_by(membership: membership)
        grant.sealed_secret_key = params[:sealed_secret_key].to_s

        if grant.save
          render json: { grant: { id: grant.key, membership_id: membership.key, key_version: current_key.version } }, status: :created
        else
          render json: ErrorSerializer.serialize(grant.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # Toggle the per-domain operational switch (enabling is guarded by the
      # Domain model: plan entitlement + a provisioned key — no half-enable)
      # and/or the notification-preview opt-in (docs/E2EE.md: rich sealed push
      # alerts at the cost of leaking exactly from + subject).
      def update
        return unless require_admin!

        if params.key?(:e2ee_enabled)
          @domain.e2ee_enabled = ActiveModel::Type::Boolean.new.cast(params[:e2ee_enabled])
        end
        if params.key?(:e2ee_notification_preview)
          @domain.e2ee_notification_preview = ActiveModel::Type::Boolean.new.cast(params[:e2ee_notification_preview])
        end
        if @domain.save
          render json: { domain: DomainSerializer.new(@domain).to_h }
        else
          render json: ErrorSerializer.serialize(@domain.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      private

      def set_domain
        @domain = current_organization.domains.find_by!(key: params[:id])
        # A domain-scoped member gets a 404 for the org's other domains (E3),
        # unless they hold a grant on its CURRENT key: a thread assigned to them
        # on that domain is sealed with it, and this is where they fetch it. A
        # grant on a retired version is access that was rotated away.
        me = current_active_membership!
        granted = @domain.current_e2ee_key&.grants&.exists?(membership_id: me.id) || false
        raise ActiveRecord::RecordNotFound unless granted || me.home_domain_ids.include?(@domain.id)
      end

      def require_admin!
        unless current_membership&.admin?
          render json: ErrorSerializer.serialize("Forbidden", status: 403), status: :forbidden
          return false
        end
        true
      end

      def active_memberships
        current_active_membership!.teammates.active
      end

      # Resolves grant membership keys → records, erroring on any stray key so a
      # mint can never silently skip (or cross-tenant) a member.
      def grant_memberships(grants)
        keys = grants.map { |g| g[:membership_id].to_s }
        found = active_memberships.where(key: keys).index_by(&:key)
        missing = keys - found.keys
        if missing.any?
          render json: ErrorSerializer.serialize("Unknown membership: #{missing.join(', ')}", status: 422), status: :unprocessable_content
          return {}
        end
        found
      end

      def my_grant_payload(current_key)
        return nil unless current_key && current_membership

        grant = current_key.grants.find_by(membership: current_membership)
        grant && {
          id: grant.key,
          key_version: current_key.version,
          sealed_secret_key: grant.sealed_secret_key
        }
      end

      def member_directory(current_key)
        granted_ids = current_key ? current_key.grants.pluck(:membership_id) : []
        active_memberships.includes(user: :user_key).map do |m|
          {
            membership_id: m.key,
            display_name: m.user&.display_name,
            role: m.role,
            public_key: m.user&.user_key&.public_key,
            has_grant: granted_ids.include?(m.id)
          }
        end
      end
    end
  end
end
