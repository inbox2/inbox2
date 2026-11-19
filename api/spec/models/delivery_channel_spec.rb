require "rails_helper"

RSpec.describe DeliveryChannel do
  let(:owner) { create(:user, username: "dchmodel") }
  let(:org) { create(:organization, owner: owner, domain: "dchmodel.com") }

  describe "kinds" do
    it "includes the built-in and the customer ESP kinds" do
      expect(DeliveryChannel::KINDS).to include("builtin", "ses", "sendgrid", "mailgun", "postmark", "messy", "smtp_relay")
    end

    it "treats everything but builtin as custom" do
      expect(DeliveryChannel.new(kind: "builtin")).to be_builtin
      expect(DeliveryChannel.new(kind: "builtin")).not_to be_custom
      DeliveryChannel::CUSTOM_KINDS.each do |kind|
        expect(DeliveryChannel.new(kind: kind)).to be_custom
      end
    end

    it "rejects an unknown kind" do
      ch = org.delivery_channels.build(name: "X", kind: "carrier_pigeon")
      expect(ch).not_to be_valid
    end
  end

  describe ".active_for" do
    it "returns the built-in when no custom default is set" do
      expect(DeliveryChannel.active_for(org)).to be_builtin
    end

    it "returns the active default custom channel when one is set" do
      DeliveryChannel.ensure_builtin(org).update!(is_default: false)
      custom = org.delivery_channels.create!(name: "SendGrid", kind: "sendgrid", status: "active", is_default: true)
      expect(DeliveryChannel.active_for(org)).to eq(custom)
    end

    it "ignores a disabled custom channel and falls back to built-in" do
      org.delivery_channels.create!(name: "SendGrid", kind: "sendgrid", status: "disabled", is_default: true)
      expect(DeliveryChannel.active_for(org)).to be_builtin
    end
  end
end
