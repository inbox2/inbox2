module Api
  module V1
    # GET /api/v1/brands/:domain — a sender domain's name, icon, hero image and
    # theme colour (docs/plans/lore.md §4b). Authenticated, not org-scoped: the
    # payload is public web data, not tenant data. See BrandFetcher.
    class BrandsController < BaseController
      def show
        domain = BrandFetcher.normalize(params[:domain])
        unless domain
          return render json: ErrorSerializer.serialize("Invalid domain", status: 422), status: :unprocessable_content
        end

        render json: BrandSerializer.new(BrandFetcher.lookup(domain)).serialize
      end
    end
  end
end
