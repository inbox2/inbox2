# Stores a fetched favicon to S3 and sets org.favicon_url to the object key (a
# user-uploaded icon_url takes precedence; the brand endpoint streams whichever
# wins). Shared by FetchFaviconJob and the fetch-icon endpoint.
module OrgIcon
  module_function

  def store!(organization, result, storage: S3StorageService.new)
    key = upload(organization, result, storage)
    organization.update!(favicon_url: key)
    key
  end

  def upload(organization, result, storage)
    ext =
      case result.content_type.to_s
      when /png/ then "png"
      when /svg/ then "svg"
      when /jpe?g/ then "jpg"
      when /gif/ then "gif"
      else "ico"
      end

    storage.upload(
      result.bytes,
      filename: "favicon.#{ext}",
      content_type: result.content_type,
      organization_key: organization.key
    )
  end
end
