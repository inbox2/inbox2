module Api
  module V1
    module Saas
      # Platform-operator view of the pre-launch waitlist: browse prospects, see
      # exactly what each one submitted, and invite them (mints a single-use token
      # + sends the on-brand invite email). Read + invite only — entries are never
      # edited or deleted here. See docs/SaaS.md.
      class WaitlistSignupsController < BaseController
        before_action :set_signup, except: %i[index]

        # GET /api/v1/saas/waitlist_signups?q=&page=&per_page=
        def index
          scope = WaitlistSignup.all
          if (q = params[:q]).present?
            like = "%#{q.strip.downcase}%"
            scope = scope.where(
              "LOWER(name) LIKE :q OR LOWER(email) LIKE :q OR LOWER(company) LIKE :q", q: like
            )
          end
          scope = scope.includes(:user)
          records, meta = paginate(scope.order(created_at: :desc), default_per_page: 25, max_per_page: 100)
          render json: { waitlist_signups: records.map { |s| serialize(s) }, meta: meta }
        end

        # GET /api/v1/saas/waitlist_signups/:id
        def show
          render json: { waitlist_signup: serialize(@signup) }
        end

        # POST /api/v1/saas/waitlist_signups/:id/invite
        def invite
          @signup.generate_invite_token!(invited_by: current_admin&.key)
          WaitlistMailerService.send_invite(@signup)
          audit!(::SaasAuditLog::ACTION_WAITLIST_INVITE, target: @signup, metadata: { email: @signup.email })
          render json: { waitlist_signup: serialize(@signup) }
        end

        private

        def set_signup
          @signup = WaitlistSignup.find_by!(key: params[:id])
        end

        def serialize(signup)
          ::Saas::WaitlistSignupSerializer.new(signup).to_h
        end
      end
    end
  end
end
