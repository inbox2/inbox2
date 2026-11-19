module Api
  module V1
    class MailFiltersController < BaseController
      before_action :require_organization!

      # spec 11.1.4, A15.1
      def index
        filters = current_organization.mail_filters.where(kind: params[:kind] || MailFilter::KIND_BLOCKLIST)
        render json: { filters: filters.map { |f| MailFilterSerializer.new(f).to_h } }
      end

      def create
        require_role!(*Membership::ADMIN_ROLES)

        filter = current_organization.mail_filters.build(filter_params)
        if filter.save
          render json: { filter: MailFilterSerializer.new(filter).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(filter.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def destroy
        require_role!(*Membership::ADMIN_ROLES)

        filter = current_organization.mail_filters.find_by!(key: params[:id])
        filter.destroy!
        head :no_content
      end

      private

      def filter_params
        params.permit(:kind, :value)
      end
    end
  end
end
