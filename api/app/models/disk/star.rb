module Disk
  class Star < ApplicationRecord
    belongs_to :organization
    belongs_to :node, class_name: "Disk::Node"
    belongs_to :membership
  end
end
