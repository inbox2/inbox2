class DataExportSerializer < ::ApplicationSerializer
  attributes :status, :byte_size, :counts, :error, :expires_at, :created_at, :updated_at
end
