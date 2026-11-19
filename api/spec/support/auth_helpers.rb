module AuthHelpers
  def auth_headers(user)
    session = user.sessions.create!(
      ip_address: "127.0.0.1",
      user_agent: "RSpec",
      last_active_at: Time.current
    )
    { "Authorization" => "Bearer #{session.token}" }
  end
end

RSpec.configure do |config|
  config.include AuthHelpers, type: :request
end
