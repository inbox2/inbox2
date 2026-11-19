class AuditLogSerializer < ::ApplicationSerializer
  attributes :action, :resource_type, :resource_id, :metadata, :created_at
end
