module Api
  module V1
    # spec 14.3, A17.3 — MCP (Model Context Protocol) server
    # Exposes inbox data as tools for AI assistants via JSON-RPC.
    #
    # Authenticated with an agent credential (agt_…), NOT a human session/API
    # key: every call resolves to an Agent record, is gated against that agent's
    # granted permissions and rate/spend limits, and is recorded in the agent's
    # run log for audit.
    class McpController < ApplicationController
      before_action :authenticate_agent!

      # tool name => permission required to invoke it (see Agent::PERMISSIONS).
      TOOLS = [
        { name: "list_conversations", permission: "read", description: "List conversations in the inbox", parameters: { status: "string", limit: "integer" } },
        { name: "get_conversation", permission: "read", description: "Get a conversation by ID with messages", parameters: { conversation_id: "string" } },
        { name: "search", permission: "read", description: "Search conversations by query", parameters: { query: "string" } },
        { name: "reply", permission: "reply", description: "Send a reply to a conversation", parameters: { conversation_id: "string", body: "string" } },
        { name: "add_tag", permission: "tag", description: "Add a tag to a conversation", parameters: { conversation_id: "string", tag: "string" } },
        { name: "set_status", permission: "set_status", description: "Set conversation status", parameters: { conversation_id: "string", status: "string" } }
      ].freeze

      def tools
        # Advertise only the tools this agent is actually permitted to call.
        permitted = TOOLS.select { |t| @current_agent.permits?(t[:permission]) }
        render json: { tools: permitted.map { |t| t.except(:permission) } }
      end

      def execute
        tool_name = params[:tool]
        tool_params = params[:params] || {}

        tool = TOOLS.find { |t| t[:name] == tool_name }
        unless tool
          return render json: ErrorSerializer.serialize("Unknown tool: #{tool_name}", status: 400), status: :bad_request
        end

        unless @current_agent.permits?(tool[:permission])
          record_run(tool_name, status: AgentRunLog::STATUS_FAILURE, error: "missing permission #{tool[:permission]}")
          return render json: ErrorSerializer.serialize("Agent not permitted to use tool: #{tool_name}", status: 403), status: :forbidden
        end

        if @current_agent.rate_limited?
          record_run(tool_name, status: AgentRunLog::STATUS_RATE_LIMITED)
          return render json: ErrorSerializer.serialize("Agent rate limit exceeded", status: 429), status: :too_many_requests
        end

        if @current_agent.spend_limited?
          record_run(tool_name, status: AgentRunLog::STATUS_FAILURE, error: "spend limit exceeded")
          return render json: ErrorSerializer.serialize("Agent spend limit exceeded", status: 429), status: :too_many_requests
        end

        result = execute_tool(tool_name, tool_params)
        record_run(tool_name, status: AgentRunLog::STATUS_SUCCESS, conversation: @last_conversation)
        render json: { result: result }
      rescue ActiveRecord::RecordNotFound => e
        record_run(tool_name, status: AgentRunLog::STATUS_FAILURE, error: e.message)
        render json: ErrorSerializer.serialize("Not found", status: 404), status: :not_found
      end

      private

      def authenticate_agent!
        token = request.headers["Authorization"]&.split(" ")&.last
        @current_agent = Agent.authenticate(token)
        return if @current_agent

        render json: ErrorSerializer.serialize("Unauthorized", status: 401), status: :unauthorized
      end

      # The agent reads through its own membership's slice (domain grants, private
      # imports excluded) — never the whole org by virtue of being an agent.
      def visible_conversations
        organization.conversations.visible_to(@current_agent.membership)
      end

      def organization
        @current_agent.organization
      end

      def record_run(action, status:, conversation: nil, error: nil)
        @current_agent.record_run!(action: action, status: status, conversation: conversation, error_message: error)
      rescue StandardError => e
        Rails.logger.warn("[McpController] failed to record agent run: #{e.message}")
      end

      def execute_tool(name, tool_params)
        case name
        when "list_conversations" then list_conversations(tool_params)
        when "get_conversation"   then get_conversation(tool_params)
        when "search"             then search_conversations(tool_params)
        when "reply"              then send_reply(tool_params)
        when "add_tag"            then add_tag_to_conversation(tool_params)
        when "set_status"         then set_conversation_status(tool_params)
        end
      end

      def list_conversations(tool_params)
        scope = visible_conversations
        scope = scope.where(status: tool_params["status"]) if tool_params["status"].present?
        limit = [tool_params["limit"].to_i, 50].min
        limit = 20 if limit <= 0

        scope.order(updated_at: :desc).limit(limit).map do |c|
          { id: c.key, subject: c.subject, status: c.status, from: c.from_address, updated_at: c.updated_at }
        end
      end

      def get_conversation(tool_params)
        conv = visible_conversations.find_by!(key: tool_params["conversation_id"])
        @last_conversation = conv
        messages = conv.messages.readable_by(@current_agent.membership).order(created_at: :asc).map do |m|
          if m.sealed?
            # E2EE: the server holds only ciphertext — agents see an explicit
            # sealed placeholder, never the content (docs/E2EE.md).
            { id: m.key, from: nil, to: nil, subject: nil, body: nil,
              encryption_scheme: m.encryption_scheme, created_at: m.created_at }
          else
            { id: m.key, from: m.from_address, to: m.to_address, subject: m.subject, body: m.body_plain&.truncate(2000), created_at: m.created_at }
          end
        end
        { id: conv.key, subject: conv.subject, status: conv.status, messages: messages }
      end

      def search_conversations(tool_params)
        query = tool_params["query"].to_s
        convs = visible_conversations
          .where("search_vector @@ plainto_tsquery('english', ?)", query)
          .order(updated_at: :desc)
          .limit(20)

        convs.map { |c| { id: c.key, subject: c.subject, status: c.status, from: c.from_address } }
      end

      def send_reply(tool_params)
        conv = visible_conversations.find_by!(key: tool_params["conversation_id"])
        @last_conversation = conv

        # Send as the agent's own membership identity — never forge the caller's.
        from_address = "#{@current_agent.membership.user.username}@#{organization.default_domain&.name}"

        # When the agent requires human approval, the reply is parked as a draft
        # and NOT enqueued for delivery; otherwise it goes through the standard
        # outbound pipeline (with the undo-send window), exactly like a person's.
        draft = @current_agent.approval_required

        # Agent sends burn the same org reputation budget as human ones.
        unless draft
          if (quota_error = SendQuota.new(organization).deny_reason(recipients: 1))
            return { error: quota_error }
          end
        end

        message = conv.messages.create!(
          organization: organization,
          from_address: from_address,
          to_address: conv.from_address,
          subject: "Re: #{conv.subject}",
          body_plain: tool_params["body"],
          is_inbound: false,
          is_draft: draft,
          # A draft is its author's: the agent's, listed in the approval queue.
          owner_membership_id: draft ? @current_agent.membership_id : nil,
          sender_membership_id: draft ? nil : @current_agent.membership_id
        )

        OutboundDeliveryJob.set(wait: Message::SEND_UNDO_WINDOW).perform_later(message.id) unless draft

        { id: message.key, status: draft ? "pending_approval" : "sent" }
      end

      def add_tag_to_conversation(tool_params)
        conv = visible_conversations.find_by!(key: tool_params["conversation_id"])
        @last_conversation = conv
        tag = organization.tags.org_wide.find_by!(name: tool_params["tag"])
        conv.tags << tag unless conv.tags.include?(tag)
        { id: conv.key, tags: conv.tags.org_wide.pluck(:name) }
      end

      def set_conversation_status(tool_params)
        conv = visible_conversations.find_by!(key: tool_params["conversation_id"])
        @last_conversation = conv
        status = tool_params["status"]
        return { error: "Invalid status" } unless Conversation::STATUSES.include?(status)

        conv.update!(status: status)
        { id: conv.key, status: conv.status }
      end
    end
  end
end
