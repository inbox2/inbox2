module Api
  module V1
    # Lore "Handled for you" auto mode (docs/Triage.md "Auto mode"): which
    # buckets file new mail away by themselves. Per person, all off by default.
    class LoreAutoController < BaseController
      # GET /api/v1/account/lore-auto
      def show
        render json: LoreAutoSerializer.new(current_user).serialize
      end

      # PUT /api/v1/account/lore-auto  { lore_auto: { fyi: true, receipt: false, notification: false } }
      def update
        raw = params.require(:lore_auto).permit(*User::LORE_AUTO_LABELS).to_h
        unless raw.values.all? { |v| [true, false].include?(v) }
          return render json: ErrorSerializer.serialize("lore_auto values must be true or false", status: 422),
                        status: :unprocessable_content
        end

        current_user.update!(lore_auto: current_user.lore_auto_settings.merge(raw))
        render json: LoreAutoSerializer.new(current_user).serialize
      end
    end
  end
end
