# Billing gateway. The single seam between our subscription flow and Stripe.
#
# When STRIPE_SECRET_KEY is configured, a real Stripe Checkout / Subscription call
# goes here (TODO: add the `stripe` gem + implement). Until then it MOCKS a
# successful subscription so "Upgrade" works end-to-end without real payment —
# returning stable fake customer/subscription ids per org.
class StripeBilling
  Result = Struct.new(:customer_id, :subscription_id, :status, keyword_init: true)

  def self.configured?
    ENV["STRIPE_SECRET_KEY"].present?
  end

  # Create/replace the org's subscription to `plan`. Returns a Result with the
  # Stripe customer + subscription ids and the resulting status.
  def self.checkout(organization:, plan:)
    return real_checkout(organization: organization, plan: plan) if configured?

    mock_checkout(organization: organization, plan: plan)
  end

  def self.real_checkout(organization:, plan:)
    raise NotImplementedError, "Real Stripe integration not wired yet — add the `stripe` gem and implement StripeBilling.real_checkout."
  end

  # Reuse the org's existing Stripe ids when present so re-subscribing (plan
  # changes) keeps one mock customer/subscription, like Stripe would.
  def self.mock_checkout(organization:, plan:)
    existing = organization.subscription
    Result.new(
      customer_id: existing&.stripe_customer_id.presence || "cus_mock_#{SecureRandom.hex(8)}",
      subscription_id: existing&.stripe_subscription_id.presence || "sub_mock_#{SecureRandom.hex(8)}",
      status: Subscription::STATUS_ACTIVE
    )
  end
end
