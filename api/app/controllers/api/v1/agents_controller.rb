module Api
  module V1
    class AgentsController < BaseController
      before_action :require_organization!

      # spec 5.5.1, A5.1-A5.2
      def index
        agents = current_organization.agents.includes(membership: [:user, :domains, { mailboxes: :domain }])
        render json: { agents: agents.map { |a| AgentSerializer.new(a).to_h } }
      end

      def show
        agent = current_organization.agents.find_by!(key: params[:id])
        render json: { agent: AgentSerializer.new(agent).to_h }
      end

      # spec 5.5.1, A5.1
      def create
        require_role!(*Membership::ADMIN_ROLES)

        # Create an agent membership
        agent_user = User.create!(
          username: "agent_#{SecureRandom.hex(6)}",
          password: SecureRandom.hex(16)
        )
        agent_membership = current_organization.memberships.create!(
          user: agent_user,
          role: Membership::ROLE_MEMBER,
          status: Membership::STATUS_ACTIVE,
          member_type: Membership::TYPE_AGENT
        )

        agent = current_organization.agents.build(
          membership: agent_membership,
          name: params[:name],
          permissions: params[:permissions] || Agent::MAIL_PERMISSIONS,
          approval_required: params[:approval_required] || false,
          supervisor_membership_id: params[:supervisor_id].present? ?
            current_organization.memberships.find_by!(key: params[:supervisor_id])&.id : nil
        )

        if agent.save
          render json: { agent: AgentSerializer.new(agent).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(agent.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec 5.5.4, A5.3
      def update
        require_role!(*Membership::ADMIN_ROLES)

        agent = current_organization.agents.find_by!(key: params[:id])
        if agent.update(agent_params)
          render json: { agent: AgentSerializer.new(agent).to_h }
        else
          render json: ErrorSerializer.serialize(agent.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec 5.5.1, A5.4
      def destroy
        require_role!(*Membership::ADMIN_ROLES)

        agent = current_organization.agents.find_by!(key: params[:id])
        agent.destroy!
        head :no_content
      end

      # spec 5.5.2, A5.5
      def credentials
        require_role!(*Membership::ADMIN_ROLES)

        agent = current_organization.agents.find_by!(key: params[:id])
        raw_token = agent.generate_credential!
        render json: { token: raw_token }, status: :created
      end

      # spec 5.5.3, A5.6
      def feed
        require_role!(*Membership::ADMIN_ROLES)

        agent = current_organization.agents.find_by!(key: params[:id])
        conversations = current_organization.conversations
          .joins(:conversation_assignees)
          .where(conversation_assignees: { membership_id: agent.membership_id })
          .order(updated_at: :desc)
          .limit(50)

        render json: { conversations: conversation_rows(conversations) }
      end

      # spec 5.5.8-5.5.9, A5.7-A5.8 — Run logs + limits
      def run_logs
        require_role!(*Membership::ADMIN_ROLES)

        agent = current_organization.agents.find_by!(key: params[:id])
        logs = agent.run_logs.recent.limit(100)
        render json: {
          run_logs: logs.map { |l| AgentRunLogSerializer.new(l).to_h },
          rate_limited: agent.rate_limited?,
          spend_limited: agent.spend_limited?
        }
      end

      # spec 5.5.7, A5.9
      def approval_queue
        require_role!(*Membership::ADMIN_ROLES)

        # Drafts an agent wrote (McpController#reply) — never a colleague's own
        # draft that happens to sit on an agent-assigned thread.
        drafts = current_organization.messages
          .where(is_draft: true, owner_membership_id: current_organization.agents.pluck(:membership_id))
          .includes(:conversation, :attachments)
          .order(created_at: :desc)

        render json: { pending_approvals: drafts.map { |d| MessageSerializer.new(d).to_h } }
      end

      private

      def agent_params
        params.permit(:name, :status, :approval_required, :rate_limit, :spend_limit_cents, permissions: [])
      end
    end
  end
end
