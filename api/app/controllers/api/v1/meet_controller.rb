module Api
  module V1
    # The public face of a meet link (docs/Calendar.md): unauthenticated,
    # capability-URL-gated. Shows busy/free only — bare start/end pairs, no
    # titles, no attendee data — and takes meeting requests behind Turnstile.
    # Unknown and revoked tokens answer identically (a generic 404) so the
    # endpoint never confirms which tokens exist.
    class MeetController < BaseController
      skip_before_action :authenticate_user!
      skip_before_action :enforce_api_key_scope!

      # Availability can be scanned week by week; a single request wider than
      # this is a scrape, not a calendar view.
      MAX_RANGE_DAYS = 31

      # GET /api/v1/meet/:token
      def show
        link = usable_link
        return link_unavailable unless link

        # The web edge fetches this with preview=1 to build link-preview tags;
        # an unfurl is not a visit.
        MeetLink.update_counters(link.id, visits_count: 1) unless params[:preview].present?
        availability = MeetAvailability.new(link, Time.current, Time.current)

        render json: {
          meet: MeetPublicSerializer.new(link, params: {
            availability: availability,
            avatar_url: avatar_url_for(link.invitee_membership.user, link),
            site_key: ENV["TURNSTILE_SITE_KEY"]
          }).to_h
        }
      end

      # GET /api/v1/meet/:token/availability?start=&end=
      def availability
        link = usable_link
        return link_unavailable unless link

        range_start = parse_time(params[:start])
        range_end = parse_time(params[:end])
        if range_start.nil? || range_end.nil? || range_end <= range_start ||
           range_end - range_start > MAX_RANGE_DAYS.days
          return render json: ErrorSerializer.serialize("invalid start/end", status: 422), status: :unprocessable_content
        end

        render json: MeetAvailability.new(link, range_start, range_end).payload
      end

      # POST /api/v1/meet/:token/requests
      def create_request
        link = usable_link
        return link_unavailable unless link

        unless TurnstileVerifier.verify(params[:turnstile_token], remote_ip: request.remote_ip)
          return render json: ErrorSerializer.serialize("Verification failed. Please try again.", status: 422),
            status: :unprocessable_content
        end

        result = MeetingRequestIntake.call(link, params.permit(:name, :email, :note, :start_at, :timezone))
        if result.ok?
          render json: { request: { id: result.request.key, status: result.request.status } }, status: :created
        else
          render json: ErrorSerializer.serialize(result.errors, status: 422), status: :unprocessable_content
        end
      end

      private

      # Active link with an invitee who is still an active member — an
      # offboarded colleague's links stop resolving without anyone revoking them.
      def usable_link
        link = MeetLink.active.find_by(token: params[:token].to_s)
        return nil unless link
        return nil unless link.invitee_membership.status == Membership::STATUS_ACTIVE

        link
      end

      def link_unavailable
        render json: ErrorSerializer.serialize("This link is not available", status: 404), status: :not_found
      end

      # The avatar stream is token-gated (see AvatarToken); a valid meet link is
      # the capability that justifies minting one for its invitee.
      def avatar_url_for(user, link)
        return nil if user.nil? || user.avatar_url.blank?
        return user.avatar_url if user.avatar_url.start_with?("http")

        UserSerializer.avatar_url(user, org_key: link.organization.key)
      end

      def parse_time(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
