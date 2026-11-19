module Api
  module V1
    # "Not available" windows (docs/Calendar.md): the member's own blocks only.
    # They surface to everyone else exclusively as anonymous busy time via
    # FreeBusy — there is no cross-member read here at all.
    class BlockedTimesController < BaseController
      before_action :require_organization!

      # GET /api/v1/orgs/:org_id/blocked-times?start=&end=
      def index
        blocks = own_blocks.order(:start_at)
        if (range = parse_range)
          blocks = blocks.in_range(range.first, range.last)
        end

        render json: { blocked_times: blocks.map { |b| BlockedTimeSerializer.new(b).to_h } }
      end

      # POST /api/v1/orgs/:org_id/blocked-times
      def create
        block = own_blocks.build(params.permit(:start_at, :end_at))
        block.organization = current_organization
        block.save!

        render json: { blocked_time: BlockedTimeSerializer.new(block).to_h }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: ErrorSerializer.serialize(e.record.errors.full_messages, status: 422), status: :unprocessable_content
      end

      # DELETE /api/v1/orgs/:org_id/blocked-times/:id
      def destroy
        own_blocks.find_by!(key: params[:id]).destroy!
        head :no_content
      end

      private

      def own_blocks
        current_active_membership!.blocked_times.where(organization: current_organization)
      end

      def parse_range
        from = Time.iso8601(params[:start].to_s) rescue nil
        to = Time.iso8601(params[:end].to_s) rescue nil
        from && to && to > from ? [from, to] : nil
      end
    end
  end
end
