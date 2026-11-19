# Shared `page`/`per_page` pagination (spec 3.4.6). Counts the full relation,
# then returns the page slice plus a meta hash for the response envelope:
#
#   records, meta = paginate(scope, default_per_page: 25, max_per_page: 100)
#   render json: { items: records.map { ... }, meta: meta }
#
# Lives in a concern so the tenant-scoped Api::V1::BaseController and the
# independent Api::V1::Saas::BaseController share one implementation (pagination
# has nothing to do with tenancy, so the SaaS base can include it without
# inheriting the tenant-scoping chokepoint).
module Paginatable
  extend ActiveSupport::Concern

  private

  def paginate(relation, default_per_page:, max_per_page:)
    page = [(params[:page] || 1).to_i, 1].max
    per_page = (params[:per_page] || default_per_page).to_i.clamp(1, max_per_page)
    total = relation.count
    records = relation.offset((page - 1) * per_page).limit(per_page)
    [records, { page: page, per_page: per_page, total: total }]
  end
end
