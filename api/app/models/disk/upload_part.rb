module Disk
  # A part number the API presigned for an upload.
  class UploadPart < ApplicationRecord
    belongs_to :organization
    belongs_to :upload, class_name: "Disk::Upload"
  end
end
