require "rails_helper"

RSpec.describe SessionRevoker do
  let(:user) { create(:user, username: "revokee") }

  it "deletes all of the user's sessions" do
    user.sessions.create!(ip_address: "1.1.1.1", user_agent: "x", last_active_at: Time.current)
    expect { described_class.revoke_user!(user) }.to change { user.sessions.count }.to(0)
  end

  it "broadcasts a force_logout on the user's push stream" do
    expect {
      described_class.revoke_user!(user)
    }.to have_broadcasted_to("push_sync_#{user.key}").with(hash_including(type: "force_logout"))
  end

  it "never raises if the live kick fails" do
    allow(ActionCable.server).to receive(:broadcast).and_raise("cable down")
    expect { described_class.revoke_user!(user) }.not_to raise_error
  end
end
