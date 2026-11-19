module Api
  module V1
    class AuditLogsController < BaseController
      before_action :require_organization!

      # spec 11.3.2, A15.5
      def index
        require_role!(*Membership::ADMIN_ROLES)

        logs = current_organization.audit_logs.recent.limit(100)
        render json: { audit_logs: logs.map { |l| AuditLogSerializer.new(l).to_h } }
      end
    end
  end
end
