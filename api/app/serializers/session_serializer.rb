class SessionSerializer
  include Alba::Resource

  attributes :ip_address, :user_agent, :last_active_at, :created_at
end
