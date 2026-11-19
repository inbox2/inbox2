module Saas
  # A waitlist prospect as seen by a platform operator: everything they submitted
  # plus lifecycle state. Exposes only public ids (E5); never the raw invite token.
  class WaitlistSignupSerializer < ::ApplicationSerializer
    attributes :name, :company, :email, :industry, :industry_label, :industry_note,
      :status, :invited_at, :registered_at, :created_at

    attribute :email_services do |s|
      s.email_services || {}
    end

    attribute :social_accounts do |s|
      s.social_accounts || {}
    end

    attribute :invited do |s|
      s.status != WaitlistSignup::STATUS_PENDING
    end

    attribute :registered_user do |s|
      next nil unless s.user

      { id: s.user.key, username: s.user.username, billing_email: s.user.billing_email }
    end
  end
end
