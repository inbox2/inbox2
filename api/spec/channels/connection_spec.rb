require "rails_helper"

RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:user) { create(:user, username: "cableuser") }

  it "connects with a valid session token" do
    session = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "RSpec", last_active_at: Time.current)
    connect params: { token: session.token }
    expect(connection.current_user).to eq(user)
  end

  it "connects with a personal API key (ink_…) for standalone clients" do
    key = user.api_keys.create!(name: "Desktop")
    connect params: { token: key.raw_token }
    expect(connection.current_user).to eq(user)
  end

  it "rejects an unknown token" do
    expect { connect params: { token: "ink_deadbeefdeadbeef" } }.to have_rejected_connection
  end

  it "rejects when no token is supplied" do
    expect { connect }.to have_rejected_connection
  end
end
