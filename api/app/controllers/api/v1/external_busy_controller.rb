module Api
  module V1
    # Busy-only upload from a member's devices (docs/Calendar.md "External
    # busy"): the Rust core reads the local Gmail/Office365 calendars and PUTs
    # bare start/end pairs here, so meet links and colleagues' free/busy see
    # meetings the server never syncs. Write-only — nothing reads these back.
    class ExternalBusyController < BaseController
      before_action :require_organization!

      # PUT /api/v1/orgs/:org_id/external-busy
      # { source: "dev_…", blocks: [{ start:, end: }, …] } — the device's whole
      # horizon; replaces whatever that device sent before.
      def update
        source = params[:source].to_s
        unless source.match?(/\A[\w.-]{1,64}\z/)
          return render json: ErrorSerializer.serialize("invalid source", status: 422), status: :unprocessable_content
        end

        blocks = params[:blocks].nil? ? [] : params[:blocks]
        unless blocks.is_a?(Array) && blocks.all? { |b| b.is_a?(ActionController::Parameters) }
          return render json: ErrorSerializer.serialize("blocks must be a list of {start, end}", status: 422), status: :unprocessable_content
        end
        if blocks.size > ExternalBusyBlock::MAX_BLOCKS
          return render json: ErrorSerializer.serialize("too many blocks", status: 422), status: :unprocessable_content
        end

        horizon = (Time.current - 1.day)..(Time.current + ExternalBusyBlock::MAX_RANGE_DAYS.days)
        periods = blocks.filter_map do |b|
          from = parse_time(b[:start])
          to = parse_time(b[:end])
          next unless from && to && to > from
          next unless from < horizon.end && to > horizon.begin

          [[from, horizon.begin].max, [to, horizon.end].min]
        end

        ExternalBusyBlock.replace!(
          membership: current_active_membership!,
          organization: current_organization,
          source: source,
          periods: periods
        )
        head :no_content
      end

      private

      def parse_time(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
