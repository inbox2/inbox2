module Api
  module V1
    module EspAdmin
      # Console side of the ESP: an org admin manages sending keys and send-only
      # domains and reads the send log.
      class BaseController < Api::V1::BaseController
        before_action :require_organization!
        before_action -> { require_role!(*Membership::ADMIN_ROLES) }
      end
    end
  end
end
