module Api
  module V1
    class MailboxesController < BaseController
      before_action :require_organization!
      # The snapshot covers every address in every domain; a domain-scoped member
      # sees pair drill-downs through visible_conversations instead.
      before_action :require_all_domains!, only: %i[graph stats]

      # GET /orgs/:org_id/mailboxes/graph
      # Returns precomputed graph snapshot
      def graph
        snapshot = current_organization.mailbox_graph_snapshot

        unless snapshot
          # Trigger first computation, return 202
          RefreshMailboxGraphJob.perform_later(current_organization.id)
          render json: { graph: nil, status: "computing" }, status: :accepted
          return
        end

        render json: { graph: MailboxGraphSnapshotSerializer.new(snapshot).to_h }
      end

      # GET /orgs/:org_id/mailboxes/stats
      # Serves the precomputed graph snapshot (refreshed every 2 min by
      # RefreshMailboxGraphJob) so the steady state never aggregates the whole
      # messages table on the request. Falls back to an inline compute only on
      # cold start (no snapshot yet), keeping the synchronous response contract.
      def stats
        snapshot = current_organization.mailbox_graph_snapshot

        if snapshot
          payload = snapshot.payload.is_a?(String) ? JSON.parse(snapshot.payload) : snapshot.payload
          render json: { nodes: payload["nodes"] || [], links: payload["links"] || [], stats: payload["stats"] || {} }
        else
          # Cold start: kick off the job and return 202 instead of aggregating the
          # whole conversations table on the request thread (mirrors #graph). The
          # client polls; empty arrays keep non-polling clients from erroring.
          RefreshMailboxGraphJob.perform_later(current_organization.id)
          render json: { nodes: [], links: [], stats: {}, status: "computing" }, status: :accepted
        end
      end

      # GET /orgs/:org_id/mailboxes/pair?source=&target=
      # Link drill-down for the Explorer: live stats + recent conversations
      # between two addresses (direction-agnostic).
      def pair
        source = params[:source].to_s.strip.downcase
        target = params[:target].to_s.strip.downcase
        if source.blank? || target.blank?
          return render json: ErrorSerializer.serialize("source and target are required", status: 400), status: :bad_request
        end

        scope = visible_conversations.where(
          "(LOWER(from_address) = :a AND LOWER(to_address) = :b) OR (LOWER(from_address) = :b AND LOWER(to_address) = :a)",
          a: source, b: target
        )
        agg = scope.pick(Arel.sql("COUNT(*), COUNT(*) FILTER (WHERE read = false), MAX(updated_at)"))
        recent = scope.includes(:tags, :space).order(updated_at: :desc).limit(5)

        render json: {
          total: agg&.first.to_i,
          unread: agg&.second.to_i,
          last_activity_at: agg&.third&.iso8601,
          conversations: conversation_rows(recent)
        }
      end

      private

      def require_all_domains!
        return if current_membership&.all_domains_access?

        render json: ErrorSerializer.serialize("Forbidden", status: 403), status: :forbidden
      end
    end
  end
end
