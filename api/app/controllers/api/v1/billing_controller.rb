module Api
  module V1
    # Org-scoped billing. The subscription belongs to the organization; the domain
    # quota is domains-per-org. Mutations require an org admin/owner.
    class BillingController < BaseController
      before_action :require_organization!
      before_action -> { require_role!(*Membership::ADMIN_ROLES) }, only: %i[subscribe update_payment_method]

      # spec 13.2.1, A16.2
      def show
        org = current_organization
        subscription = org.subscription
        plan = org.effective_plan

        render json: {
          plan: PlanSerializer.new(plan).to_h,
          status: subscription&.status || Plan::TIER_FREE,
          trial_ends_at: subscription&.trial_ends_at,
          current_period_ends_at: subscription&.current_period_ends_at,
          # Domain usage drives the admin console's "X of Y domains" indicator and
          # gates the Add-domain button — now counted per org (spec 13.1.4).
          domains_used: org.domains.count,
          domain_limit_reached: org.domain_limit_reached?,
          collaborators_used: org.collaborator_count,
          collaborator_limit_reached: org.collaborator_limit_reached?,
          locked_domains: org.domains.where.not(locked_at: nil).count
        }
      end

      # spec 13.1.2, A16.3 — change plan (up or down). Payment runs through
      # StripeBilling (mocked for now). A downgrade that exceeds the target plan's
      # limits requires `acknowledge` (the client shows a confirm + checkbox);
      # after the switch, over-limit domains are locked + extra collaborators
      # disabled (Organization#apply_plan_limits!).
      def subscribe
        Plan.ensure_seeded!
        org = current_organization
        plan = Plan.find_by!(key: params[:plan_id])
        downgrade = plan.price_cents < org.effective_plan.price_cents

        if downgrade && org.over_plan_limits?(plan) && !acknowledged?
          return render json: {
            errors: [{ message: "This downgrade locks resources beyond the plan's limits" }],
            code: "downgrade_requires_acknowledgement",
            impact: org.downgrade_impact(plan),
            status: 422
          }, status: :unprocessable_content
        end

        result = StripeBilling.checkout(organization: org, plan: plan)
        subscription = org.subscription || org.build_subscription
        subscription.assign_attributes(
          plan: plan,
          status: result.status || Subscription::STATUS_ACTIVE,
          stripe_customer_id: result.customer_id,
          stripe_subscription_id: result.subscription_id,
          current_period_ends_at: 30.days.from_now
        )
        subscription.save!
        org.apply_plan_limits!(plan)

        render json: { subscription: SubscriptionSerializer.new(subscription).to_h }
      end

      # spec 13.2.1, A16.5
      def invoices
        render json: { invoices: [] }
      end

      # spec 13.2.1, A16.6
      def update_payment_method
        render json: { message: "Payment method updated" }
      end

      private

      def acknowledged?
        ActiveModel::Type::Boolean.new.cast(params[:acknowledge])
      end
    end
  end
end
