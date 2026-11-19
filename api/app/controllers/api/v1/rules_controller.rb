module Api
  module V1
    class RulesController < BaseController
      before_action :require_organization!

      PREVIEW_SCAN_LIMIT = 500
      PREVIEW_SAMPLE_LIMIT = 12

      # spec 7.1.1, A11.1
      def index
        require_role!(*Membership::ADMIN_ROLES)

        rules = current_organization.rules.ordered
        render json: { rules: rules.map { |r| RuleSerializer.new(r).to_h } }
      end

      # spec 7.1.1, A11.1
      def create
        require_role!(*Membership::ADMIN_ROLES)

        rule = current_organization.rules.build(rule_params)
        rule.position = current_organization.rules.count

        if rule.save
          render json: { rule: RuleSerializer.new(rule).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(rule.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec 7.1.1, A11.1
      def update
        require_role!(*Membership::ADMIN_ROLES)

        rule = current_organization.rules.find_by!(key: params[:id])

        if rule.update(rule_params)
          render json: { rule: RuleSerializer.new(rule).to_h }
        else
          render json: ErrorSerializer.serialize(rule.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec 7.1.1, A11.1
      def destroy
        require_role!(*Membership::ADMIN_ROLES)

        rule = current_organization.rules.find_by!(key: params[:id])
        rule.destroy!
        head :no_content
      end

      # spec 7.1.2, A11.2
      def reorder
        require_role!(*Membership::ADMIN_ROLES)

        rule_ids = params[:rule_ids] || []
        rule_ids.each_with_index do |rule_key, index|
          current_organization.rules.where(key: rule_key).update_all(position: index)
        end

        render json: { rules: current_organization.rules.ordered.map { |r| RuleSerializer.new(r).to_h } }
      end

      # spec 7.1.2, A11.3
      def toggle
        require_role!(*Membership::ADMIN_ROLES)

        rule = current_organization.rules.find_by!(key: params[:id])
        rule.update!(enabled: !rule.enabled)
        render json: { rule: RuleSerializer.new(rule).to_h }
      end

      # spec 7.1.5, A11.5 — Per-rule run log
      def run_log
        require_role!(*Membership::ADMIN_ROLES)

        rule = current_organization.rules.find_by!(key: params[:id])
        logs = rule.rule_logs.recent.limit(50)
        render json: { run_log: logs.map { |l| RuleLogSerializer.new(l).to_h } }
      end

      # Preview matches for an UNSAVED rule (the create-wizard review step). Unlike
      # dry_run (which needs a persisted rule), this evaluates inline conditions
      # against recent conversations so the wizard can show "N existing emails
      # match" before the rule is saved. Read-only — never applies actions.
      def preview
        require_role!(*Membership::ADMIN_ROLES)

        conditions = preview_conditions
        if conditions.empty?
          return render json: { samples: [], total: 0, scanned_capped: false }
        end

        executor = RuleExecutor.new(current_organization)
        scan = current_organization.conversations.org_readable
          .includes(messages: :attachments)
          .order(updated_at: :desc)
          .limit(PREVIEW_SCAN_LIMIT)
        matches = scan.filter_map do |conv|
          msg = conv.messages.max_by { |m| [m.created_at, m.id] }
          next unless msg && executor.match_rule?(conditions, conv, msg)

          [conv, msg]
        end

        render json: {
          # Lightweight sample rows (from/subject) — matches the create-wizard's
          # preview shape; a sealed message has no plaintext sender (nil → the UI
          # shows "unknown sender").
          samples: matches.first(PREVIEW_SAMPLE_LIMIT).map do |conv, msg|
            { message_key: msg.key, from: msg.from_address, subject: conv.subject }
          end,
          total: matches.length,
          scanned_capped: scan.length >= PREVIEW_SCAN_LIMIT
        }
      end

      # "Apply to existing emails" backfill (spec 7.1.6) — enqueue the rule over the
      # org's already-received mail. Async so a large mailbox doesn't block the
      # request; see RuleBackfillJob.
      def apply_existing
        require_role!(*Membership::ADMIN_ROLES)

        rule = current_organization.rules.find_by!(key: params[:id])
        RuleBackfillJob.perform_later(rule.id)
        render json: { enqueued: true }, status: :accepted
      end

      # spec 7.1.6, A11.4 — Dry run
      def dry_run
        require_role!(*Membership::ADMIN_ROLES)

        rule = current_organization.rules.find_by!(key: params[:id])
        executor = RuleExecutor.new(current_organization)

        matches = current_organization.conversations.org_readable
          .includes(:messages)
          .order(updated_at: :desc)
          .limit(20)
          .select do |conv|
            msg = conv.messages.last
            next false unless msg
            executor.match_rule?(rule.conditions, conv, msg)
          end

        render json: {
          matches: matches.map { |c| ConversationSerializer.new(c).to_h },
          count: matches.length
        }
      end

      private

      def rule_params
        params.permit(
          :name, :enabled, :stop_processing,
          conditions: [:field, :operator, :value],
          actions: [:type, :value],
          branches: [conditions: [:field, :operator, :value], actions: [:type, :value]],
          else_actions: [:type, :value]
        )
      end

      # Inline conditions for the unsaved-rule preview, normalized to string-keyed
      # hashes (RuleExecutor#match_rule? reads condition["field"] etc.).
      def preview_conditions
        permitted = params.permit(conditions: [:field, :operator, :value])
        (permitted[:conditions] || []).map(&:to_h).select do |c|
          c["field"].present? && c["operator"].present?
        end
      end
    end
  end
end
