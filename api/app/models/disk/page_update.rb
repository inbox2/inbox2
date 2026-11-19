module Disk
  # A stored sealed page update (6.10): ciphertext at a page-wide seq.
  class PageUpdate < ApplicationRecord
    belongs_to :organization
    belongs_to :node, class_name: "Disk::Node"
  end
end
