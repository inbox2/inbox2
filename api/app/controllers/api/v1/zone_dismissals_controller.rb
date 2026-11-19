module Api
  module V1
    # Zone start cards clicked away (docs/Calendar.md "Zones"), shared across the
    # user's devices. POST is idempotent; each one tells the other devices.
    class ZoneDismissalsController < BaseController
      # GET /api/v1/account/zone-dismissals — the ones still relevant.
      def index
        rows = current_user.zone_dismissals.live.order(:end_at)
        render json: { zone_dismissals: rows.map { |d| ZoneDismissalSerializer.new(d).to_h } }
      end

      # POST /api/v1/account/zone-dismissals { occurrence_id, end_at }
      def create
        occurrence_id = params[:occurrence_id].to_s
        # Only your own zones: an unknown or someone else's series 404s.
        current_user.zones.find_by!(key: occurrence_id.split("@").first)

        row = current_user.zone_dismissals.find_or_initialize_by(occurrence_id: occurrence_id)
        created = row.new_record?
        row.end_at = params[:end_at]
        row.save!
        current_user.zone_dismissals.where("end_at < ?", Time.current - ZoneDismissal::RETENTION).delete_all
        ZoneSync.notify(current_user, dismissed: occurrence_id) if created

        render json: { zone_dismissal: ZoneDismissalSerializer.new(row).to_h }, status: created ? :created : :ok
      rescue ActiveRecord::RecordInvalid => e
        render json: ErrorSerializer.serialize(e.record.errors.full_messages, status: 422), status: :unprocessable_content
      rescue ActiveRecord::RecordNotUnique
        # Two devices clicking Done at once: the other one won, same outcome.
        render json: { zone_dismissal: ZoneDismissalSerializer.new(current_user.zone_dismissals.find_by!(occurrence_id: occurrence_id)).to_h }
      end
    end
  end
end
