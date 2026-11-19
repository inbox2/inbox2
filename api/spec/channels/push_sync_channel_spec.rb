require "rails_helper"

RSpec.describe PushSyncChannel, type: :channel do
  let(:user) { create(:user, username: "pushstream") }

  before { stub_connection current_user: user }

  it "streams from the per-user push channel" do
    subscribe
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("push_sync_#{user.key}")
  end
end
