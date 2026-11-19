module Api
  module V1
    # The user's zone categories (docs/Calendar.md "Zones"). The first list seeds
    # the defaults (Deep work / Prep / Admin / Personal), so every client starts
    # with the same set without a separate setup step.
    class ZoneCategoriesController < BaseController
      # A renamed or recoloured category restyles zones on every device.
      after_action :notify_devices, only: %i[create update destroy]

      # GET /api/v1/account/zone-categories
      def index
        # Locked: two clients opening the calendar at once would both see none
        # and seed the defaults twice.
        current_user.with_lock do
          ZoneCategory.seed_defaults!(current_user) unless current_user.zone_categories.exists?
        end
        render json: { zone_categories: current_user.zone_categories.reload.map { |c| ZoneCategorySerializer.new(c).to_h } }
      end

      # POST /api/v1/account/zone-categories
      def create
        category = current_user.zone_categories.build(category_params)
        category.position = current_user.zone_categories.maximum(:position).to_i + 1 unless params.key?(:position)
        category.save!
        render json: { zone_category: ZoneCategorySerializer.new(category).to_h }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render_invalid(e)
      end

      # PATCH /api/v1/account/zone-categories/:id
      def update
        category = current_user.zone_categories.find_by!(key: params[:id])
        category.update!(category_params)
        render json: { zone_category: ZoneCategorySerializer.new(category).to_h }
      rescue ActiveRecord::RecordInvalid => e
        render_invalid(e)
      end

      # DELETE /api/v1/account/zone-categories/:id — its zones stay, uncategorised.
      def destroy
        current_user.zone_categories.find_by!(key: params[:id]).destroy!
        head :no_content
      end

      private

      def notify_devices
        ZoneSync.notify(current_user) if response.successful?
      end

      def category_params
        params.permit(:name, :color, :position)
      end

      def render_invalid(error)
        render json: ErrorSerializer.serialize(error.record.errors.full_messages, status: 422), status: :unprocessable_content
      end
    end
  end
end
