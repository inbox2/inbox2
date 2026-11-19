module Api
  module V1
    # Calendar zones (docs/Calendar.md "Zones"): the signed-in user's own soft
    # focus blocks. User-scoped — there is no way to read anyone else's.
    #
    # The list returns occurrences (a repeating zone expands across the window);
    # PATCH/DELETE take either the series key or an occurrence id
    # ("zon_x@20260925T140000Z"). Deleting an occurrence deletes the series,
    # unless `scope=occurrence` asks to drop just that day.
    class ZonesController < BaseController
      DEFAULT_BACK = 7.days
      DEFAULT_AHEAD = 60.days
      MAX_WINDOW = 400.days

      # Every successful write tells the user's other devices (ZoneSync).
      after_action :notify_devices, only: %i[create update destroy]

      # GET /api/v1/account/zones?start=&end=
      def index
        from, to = parse_range || [Time.current - DEFAULT_BACK, Time.current + DEFAULT_AHEAD]
        to = [to, from + MAX_WINDOW].min
        occurrences = current_user.zones.includes(:zone_category, :user).touching(from, to)
          .flat_map { |z| z.occurrences(from, to) }
          .sort_by(&:start_at)

        dismissed = current_user.zone_dismissals.where(occurrence_id: occurrences.map(&:id)).pluck(:occurrence_id).to_set
        render json: {
          zones: occurrences.map { |o| ZoneSerializer.new(o).to_h.merge("dismissed" => dismissed.include?(o.id)) }
        }
      end

      # POST /api/v1/account/zones
      def create
        zone = current_user.zones.build(zone_params)
        zone.save!
        render json: { zone: ZoneSerializer.one(zone) }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render_invalid(e)
      end

      # PATCH /api/v1/account/zones/:id
      def update
        zone = find_zone
        attrs = zone_params
        # Retiming one occurrence of a repeating zone retimes the series the same
        # way (Zone#shift_from_occurrence). Turning the repeat off instead keeps
        # the occurrence being edited, at the times sent.
        stops_repeating = attrs.key?(:repeat) && attrs[:repeat] == Zone::REPEAT_NONE
        if (at = occurrence_start) && zone.repeating? && !stops_repeating && attrs[:start_at] && attrs[:end_at]
          zone.shift_from_occurrence(at, Time.zone.parse(attrs.delete(:start_at).to_s), Time.zone.parse(attrs.delete(:end_at).to_s))
        end
        zone.assign_attributes(attrs)
        zone.save!
        # An edited zone should alert again, so its old dismissals go.
        clear_dismissals(zone)
        render json: { zone: ZoneSerializer.one(zone) }
      rescue ActiveRecord::RecordInvalid => e
        render_invalid(e)
      end

      # DELETE /api/v1/account/zones/:id[?scope=occurrence]
      def destroy
        zone = find_zone
        # Never fall through to deleting the series on a malformed request: an
        # unknown scope, or an id that isn't a real occurrence of this series.
        if params.key?(:scope)
          at = occurrence_start
          real = params[:scope] == "occurrence" && zone.repeating? && at &&
            zone.occurrences(at, at + 1.second).any? { |o| o.start_at == at }
          unless real
            return render json: ErrorSerializer.serialize(["Not an occurrence of a repeating zone"], status: 422),
                          status: :unprocessable_content
          end
          zone.skip_occurrence(at)
          return head :no_content
        end
        clear_dismissals(zone)
        zone.destroy!
        head :no_content
      end

      private

      def clear_dismissals(zone)
        current_user.zone_dismissals
          .where("occurrence_id = ? OR occurrence_id LIKE ?", zone.key, "#{zone.key}@%")
          .delete_all
      end

      def notify_devices
        ZoneSync.notify(current_user) if response.successful?
      end

      def find_zone
        current_user.zones.find_by!(key: params[:id].to_s.split("@").first)
      end

      def occurrence_start
        stamp = params[:id].to_s.split("@", 2)[1]
        stamp && (Time.strptime(stamp, "%Y%m%dT%H%M%S%z") rescue nil)
      end

      def zone_params
        permitted = params.permit(:name, :note, :start_at, :end_at, :notify, :blocks, :repeat, :repeat_until,
          :time_zone, :anchor_event_id, :anchor_minutes)
        # `category_id` is the category's public key; null clears it. An unknown
        # or someone else's category 404s rather than silently dropping.
        if params.key?(:category_id)
          permitted[:zone_category] = params[:category_id].presence &&
            current_user.zone_categories.find_by!(key: params[:category_id])
        end
        permitted
      end

      def render_invalid(error)
        render json: ErrorSerializer.serialize(error.record.errors.full_messages, status: 422), status: :unprocessable_content
      end

      def parse_range
        from = Time.iso8601(params[:start].to_s) rescue nil
        to = Time.iso8601(params[:end].to_s) rescue nil
        from && to && to > from ? [from, to] : nil
      end
    end
  end
end
