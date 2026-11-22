module Api
  module V1
    class BaseController < ApplicationController
      include Paginatable

      class Forbidden < StandardError; end
      rescue_from(Forbidden) { render json: ErrorSerializer.serialize("Forbidden", status: 403), status: :forbidden }

      before_action :authenticate_user!
      before_action :enforce_api_key_scope!
      before_action { Current.membership_resolver = -> { current_membership if current_user } }
      after_action :broadcast_sync_hint

      # How long one "something changed" nudge covers an org + scope, per process
      # (docs/MX-Sync.md). In-memory on purpose: the cache store is Postgres-backed
      # in prod, and a debounce must not cost every write a query.
      SYNC_HINT_DEBOUNCE = 1.0
      SYNC_HINT_SENT = Concurrent::Map.new
      # Writes from these controllers change mail; anything else is directory
      # (tags, members, domains, spaces, labels, views…), which clients re-list.
      SYNC_MAIL_CONTROLLERS = %w[conversations messages notes assignment attachments].freeze

      private

      # Block mutating requests made with a read-only personal API key. Session
      # (web) auth carries no key and is unaffected.
      def enforce_api_key_scope!
        return unless current_api_key
        return if current_api_key.allows_request?(request.request_method)

        render json: ErrorSerializer.serialize("API key not authorized for this action (missing write scope)", status: 403),
          status: :forbidden
      end

      def current_organization
        @current_organization ||= begin
          org_id = params[:org_id] || params[:organization_id]
          return nil unless org_id

          scope = current_user.accessible_organizations
          # Support lookup by key (org_xxx) or slug (acme-corp)
          scope.find_by(key: org_id) || scope.find_by!(slug: org_id)
        end
      end

      def require_organization!
        render json: ErrorSerializer.serialize("Organization not found", status: 404), status: :not_found unless current_organization
      end

      # The acting user's *active* membership in the current org (or nil). Disabled
      # and not-yet-accepted (invited) memberships intentionally carry no rights,
      # so they're excluded. Single source of truth for role gating.
      def current_membership
        return @current_membership if defined?(@current_membership)

        @current_membership = current_organization&.memberships&.find_by(
          user: current_user, status: Membership::STATUS_ACTIVE
        )
      end

      # Same as current_membership but required: raises RecordNotFound (→ 404)
      # when the acting user has no active membership in the current org.
      def current_active_membership!
        @current_active_membership ||= current_organization.memberships.find_by!(
          user: current_user, status: Membership::STATUS_ACTIVE
        )
      end

      # Raises, so a call inside an action stops it: a check that only rendered let the
      # action run on unless every caller remembered to `return if performed?`.
      def require_role!(*roles)
        raise Forbidden unless current_membership && roles.map(&:to_s).include?(current_membership.role)
      end

      # Nudge the org's other devices to pull after any successful write, so a
      # teammate's archive/read/assign arrives without waiting out the poll. A hint
      # only — it carries no data, and a lost one costs a poll interval.
      def broadcast_sync_hint
        return if request.get? || request.head? || !response.successful? || @current_organization.nil?

        # "disk": Disk in Finder pulls on it (docs/Disk-Sync.md); mail and directory clients ignore it.
        scope =
          if self.class.name.start_with?("Api::V1::Disk::") then "disk"
          elsif SYNC_MAIL_CONTROLLERS.include?(controller_name) then "mail"
          else "directory"
          end
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        slot = "#{@current_organization.id}:#{scope}"
        last = SYNC_HINT_SENT[slot]
        return if last && now - last < SYNC_HINT_DEBOUNCE

        SYNC_HINT_SENT[slot] = now
        ActionCable.server.broadcast("organization_#{@current_organization.key}", { type: "sync", scope: scope })
      rescue => e
        Rails.logger.warn("[Sync] hint broadcast error: #{e.message}")
      end

      # The pool the acting member may see: tenant-scoped AND domain-scoped to
      # their grants (owners/admins + all-domains members see everything). Use
      # this for every member-facing conversation read/mutation so a domain-scoped
      # member never sees or touches another domain's mail. Falls back to the raw
      # org pool when there's no membership context (shouldn't happen post-auth).
      def visible_conversations
        scope = current_organization.conversations
        current_membership ? scope.visible_to(current_membership) : scope.org_readable
      end

      # List rows for any endpoint that renders ConversationSerializer in bulk
      # (inbox index, search, agent feed, mailbox pair): the row-level preloads
      # plus the one-query paperclip set. Anything else re-runs the assignee,
      # user and attachments lookups per row — search did, at 50 rows a page.
      def conversation_rows(conversations)
        rows = conversations.respond_to?(:includes) ? conversations.includes(:tags, :space, :lore_member_dones, assignees: :user).to_a : conversations.to_a
        with_attachments = Attachment
          .joins(:message)
          .where(messages: { conversation_id: rows.map(&:id) })
          .merge(Message.readable_by(current_membership))
          .distinct
          .pluck("messages.conversation_id")
          .to_set
        rows.map { |c| ConversationSerializer.new(c, params: { with_attachments: with_attachments }).to_h }
      end

      # Whether the member may send as this address: on an org domain they can
      # see, under their own name there (their username, which every client
      # offers as From, or one of their mailboxes). Codex review of 46b82854:
      # without it any member could send as anyone on any of the org's domains.
      def sendable_from?(address)
        return true unless current_membership

        current_membership.can_send_as?(address)
      end

      def refuse_sender(address)
        render json: ErrorSerializer.serialize("You can't send as #{address}", status: 403), status: :forbidden
      end

      # The org's Domain a sending address belongs to. A new outbound thread
      # must carry it: the Sent view and domain-scoped members filter on
      # conversations.domain_id, so a nil one is invisible there.
      def sender_domain(address)
        host = MailHeaderEncoding.bare_addresses(address.to_s).first&.split("@")&.last&.downcase
        host.present? ? current_organization.domains.find_by(name: host) : nil
      end
    end
  end
end
