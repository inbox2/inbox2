module Api
  module V1
    # GET /api/v1/avatars?email=<address> — the picture for a sender, as image
    # bytes (AvatarResolver picks the source; the image proxy fetches it, so the
    # reader's IP never reaches Gravatar or the sender's site). 404 when there is
    # none: the client draws initials. Authenticated, not org-scoped — it serves
    # public web images only, never a member's uploaded photo.
    class AvatarsController < ImageProxyController
      def show
        url = AvatarResolver.lookup(params[:email])
        return render json: ErrorSerializer.serialize("No avatar", status: 404), status: :not_found unless url

        params[:url] = url
        super
      end

      private

      # SVG is the one image type the phones can't decode; initials beat a blank.
      def deliver(response)
        return render json: ErrorSerializer.serialize("No avatar", status: 404), status: :not_found if response["Content-Type"].to_s.include?("svg")

        super
      end
    end
  end
end
