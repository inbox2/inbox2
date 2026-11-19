# BrandFetcher::Brand payload (BrandsController). No public id, so Alba::Resource
# directly rather than ApplicationSerializer.
class BrandSerializer
  include Alba::Resource

  root_key :brand
  attributes :domain, :name, :icon_url, :image_url, :theme_color
end
