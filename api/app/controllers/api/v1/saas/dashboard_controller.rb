module Api
  module V1
    module Saas
      # Account-wide operational metrics (org/user/mailbox counts, plan split,
      # mail volume) for the SaaS operations dashboard.
      class DashboardController < BaseController
        def show
          render json: { metrics: ::Saas::DashboardMetrics.new.call }
        end
      end
    end
  end
end
