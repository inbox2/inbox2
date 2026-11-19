module Api
  module V1
    class PlansController < BaseController
      skip_before_action :authenticate_user!, only: :index

      # spec 13.1.1-13.1.2, A16.1
      def index
        Plan.ensure_seeded!
        plans = Plan.all.order(:price_cents)
        render json: { plans: plans.map { |p| PlanSerializer.new(p).to_h } }
      end
    end
  end
end
