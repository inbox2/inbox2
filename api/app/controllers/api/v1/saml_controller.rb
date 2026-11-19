module Api
  module V1
    # spec 2.1.7, A1.11 — SAML SSO
    #
    # Who a NameID is, is decided by one table — SamlIdentity — and nothing else.
    # The old lookup matched the NameID's local-part against usernames, which let
    # an org admin (who controls the IdP config) assert `owner@anything` and
    # receive the owner's user-wide session. Now:
    #
    #   * a signed-in member binds their IdP identity once (#link → IdP → #consume
    #     with a signed RelayState naming them);
    #   * a NameID with an identity logs that user in;
    #   * a NameID nobody has linked is provisioned as a NEW member — unless it
    #     collides with an existing member's address, in which case they are told
    #     to link first (409) rather than being matched by name.
    #
    # The IdP form-POSTs to #consume (the ACS). A browser gets bounced to the web
    # app with a two-minute single-use ticket that #exchange turns into a session;
    # a JSON caller (tests, native clients) gets the session straight back.
    class SamlController < BaseController
      PUBLIC_ACTIONS = %i[initiate consume metadata exchange].freeze

      before_action :require_organization!, except: PUBLIC_ACTIONS
      skip_before_action :authenticate_user!, only: PUBLIC_ACTIONS

      LINK_STATE_TTL = 10.minutes
      LOGIN_TICKET_TTL = 2.minutes

      # Admin: configure SAML for org
      def configure
        require_role!(*Membership::ADMIN_ROLES)

        config = current_organization.saml_config || current_organization.build_saml_config
        config.assign_attributes(saml_params)

        if config.save
          render json: { saml_config: SamlConfigSerializer.new(config).to_h }, status: config.previously_new_record? ? :created : :ok
        else
          render json: ErrorSerializer.serialize(config.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def show
        config = current_organization.saml_config
        if config
          render json: { saml_config: SamlConfigSerializer.new(config).to_h }
        else
          render json: { saml_config: nil }
        end
      end

      def destroy
        require_role!(*Membership::ADMIN_ROLES)

        current_organization.saml_config&.destroy
        head :no_content
      end

      # SP-initiated SSO — redirect to IdP
      def initiate
        org = public_org!
        config = enabled_config!(org, status: :not_found) or return

        request = OneLogin::RubySaml::Authrequest.new
        redirect_url = request.create(config.saml_settings)
        render json: { redirect_url: redirect_url }
      end

      # The signed-in member's own identity in this org (what Settings shows).
      def identity
        identity = current_organization.saml_identities.find_by(user: current_user)
        render json: { saml_identity: identity && SamlIdentitySerializer.new(identity).to_h }
      end

      # POST /orgs/:org_id/saml/link — start an IdP round-trip that binds the
      # resulting NameID to the signed-in member. The RelayState is a signed,
      # short-lived, single-use statement of who is linking; #consume honours it
      # only for this org and only while the member is still active.
      def link
        membership = current_active_membership!
        config = enabled_config!(current_organization, status: :not_found) or return

        state = self.class.verifier.generate(
          { "user_id" => membership.user_id, "org_id" => current_organization.id, "nonce" => SecureRandom.hex(12) },
          purpose: :saml_link, expires_in: LINK_STATE_TTL
        )
        redirect_url = OneLogin::RubySaml::Authrequest.new.create(config.saml_settings, "RelayState" => state)
        render json: { redirect_url: redirect_url }
      end

      def unlink
        current_organization.saml_identities.where(user: current_user).destroy_all
        head :no_content
      end

      # SAML ACS — consume assertion
      def consume
        org = public_org!
        config = enabled_config!(org, status: :unprocessable_content) or return

        response = OneLogin::RubySaml::Response.new(
          params[:SAMLResponse],
          settings: config.saml_settings,
          allowed_clock_drift: 30.seconds
        )

        unless response.is_valid?
          Rails.logger.warn("[SAML] Validation failed for org #{org.key}: #{response.errors.join(', ')}")
          return render json: ErrorSerializer.serialize("SAML authentication failed", status: 422),
            status: :unprocessable_content
        end

        # Replay protection: each assertion ID may be consumed once. A captured,
        # still-valid SAMLResponse (incl. IdP-initiated) can't be reused to mint
        # a second session. Unique index on assertion_id enforces this atomically.
        unless SamlAssertion.consume(response.assertion_id, org)
          Rails.logger.warn("[SAML] Replayed assertion #{response.assertion_id} for org #{org.key}")
          return render json: ErrorSerializer.serialize("SAML assertion already used", status: 422),
            status: :unprocessable_content
        end

        name_id = response.nameid.to_s.strip
        if name_id.blank?
          return render json: ErrorSerializer.serialize("SAML assertion carries no NameID", status: 422),
            status: :unprocessable_content
        end

        user = resolve_saml_user(org, name_id, link_state(params[:RelayState], org))
        return if performed?

        if json_request?
          session = create_session_for(user)
          render json: { token: session.raw_token, user: UserSerializer.new(user).to_h }
        else
          redirect_to web_callback_url(login_ticket_for(user)), allow_other_host: true
        end
      end

      # POST /auth/saml/exchange { ticket } — the web app, landed on from the ACS
      # redirect, trades the one-time ticket for a real session.
      def exchange
        payload = self.class.verifier.verified(params[:ticket].to_s, purpose: :saml_login)
        unless payload && claim_once!("saml:login:#{payload['nonce']}", LOGIN_TICKET_TTL)
          return render json: ErrorSerializer.serialize("Invalid or expired SSO ticket", status: 401), status: :unauthorized
        end

        user = User.find(payload["user_id"])
        session = create_session_for(user)
        render json: { token: session.raw_token, user: UserSerializer.new(user).to_h }
      end

      # SP metadata
      def metadata
        org = public_org!
        config = org.saml_config
        unless config
          return render json: ErrorSerializer.serialize("SAML not configured", status: 404), status: :not_found
        end

        meta = OneLogin::RubySaml::Metadata.new
        render xml: meta.generate(config.saml_settings, true)
      end

      def self.verifier = Rails.application.message_verifier(:saml)

      private

      # The unauthenticated routes take the org key or its slug: the login page
      # asks the person for the slug (the first segment of their inbox2 URLs).
      def public_org!
        id = params[:org_id].to_s
        Organization.teams.find_by(key: id) || Organization.teams.find_by!(slug: id)
      end

      def saml_params
        params.permit(:idp_entity_id, :idp_sso_url, :idp_certificate, :name_id_format, :enabled)
      end

      def enabled_config!(org, status:)
        config = org.saml_config
        return config if config&.enabled?

        render json: ErrorSerializer.serialize("SAML not configured for this organization", status: Rack::Utils.status_code(status)),
               status: status
        nil
      end

      # The identity's user: linking binds, a known NameID logs in, an unknown
      # one is provisioned — never matched by name. Renders the error and returns
      # nil when the login must not proceed.
      def resolve_saml_user(org, name_id, link)
        identity = org.saml_identities.find_by(name_id: name_id)

        if link
          user = User.find_by(id: link["user_id"])
          unless user && org.memberships.active.exists?(user: user)
            return refuse("Only an active member can link an SSO identity", 403)
          end
          if identity && identity.user_id != user.id
            return refuse("This SSO identity is already linked to another account", 409)
          end

          identity ||= org.saml_identities.create!(user: user, name_id: name_id)
        elsif identity
          user = identity.user
          return refuse("Your membership in this organization is not active", 403) unless org.memberships.active.exists?(user: user)
        else
          if member_address_taken?(org, name_id)
            return refuse("An account with this address already exists — sign in and link SSO from Settings first", 409)
          end

          user = provision_saml_user(org, name_id)
          identity = org.saml_identities.create!(user: user, name_id: name_id)
        end

        identity.update_column(:last_login_at, Time.current)
        user
      end

      # Does an ACTIVE member of this org already own `name_id` as an address
      # (external billing address or an org mailbox)? Then SSO must not mint a
      # second account for them; they link theirs while signed in.
      def member_address_taken?(org, name_id)
        addr = name_id.downcase
        return true if org.memberships.active.joins(:user).where("LOWER(users.billing_email) = ?", addr).exists?

        Mailbox.joins(:domain, :membership)
          .where(memberships: { organization_id: org.id, status: Membership::STATUS_ACTIVE })
          .where("LOWER(mailboxes.local_part || '@' || domains.name) = ?", addr)
          .exists?
      end

      def provision_saml_user(org, name_id)
        base = name_id.split("@").first.to_s.downcase.gsub(/[^a-z0-9_\-]/, "").presence || "sso"
        base = base.ljust(3, "0")
        username = base
        username = "#{base}_#{SecureRandom.hex(3)}" while User.exists?(username: username)

        attrs = { username: username, password: SecureRandom.hex(24) }
        attrs[:billing_email] = name_id if name_id.include?("@") && !User.exists?(billing_email: name_id)
        user = User.create!(attrs)
        org.memberships.create!(user: user, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
        user
      end

      # The link statement from #link, or nil: wrong org, expired, tampered or
      # already spent all read as "no link".
      def link_state(relay, org)
        return nil if relay.blank?

        payload = self.class.verifier.verified(relay, purpose: :saml_link)
        return nil unless payload && payload["org_id"] == org.id
        return nil unless claim_once!("saml:link:#{payload['nonce']}", LINK_STATE_TTL)

        payload
      end

      def login_ticket_for(user)
        self.class.verifier.generate(
          { "user_id" => user.id, "nonce" => SecureRandom.hex(12) },
          purpose: :saml_login, expires_in: LOGIN_TICKET_TTL
        )
      end

      def claim_once!(cache_key, ttl)
        Rails.cache.write(cache_key, true, expires_in: ttl, unless_exist: true)
      end

      def web_callback_url(ticket)
        base = ENV.fetch("WEB_APP_URL", "https://app.inbox2.com").chomp("/")
        "#{base}/sso/saml/callback?ticket=#{CGI.escape(ticket)}"
      end

      def json_request?
        request.format.json? || request.xhr?
      end

      def refuse(message, status)
        render json: ErrorSerializer.serialize(message, status: status), status: status
        nil
      end
    end
  end
end
