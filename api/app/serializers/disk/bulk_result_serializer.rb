module Disk
  # One item of a bulk request: the item id, whether it went through, and why not.
  class BulkResultSerializer
    include Alba::Resource

    Result = Struct.new(:id, :ok, :error, :node, keyword_init: true)

    attributes :id, :ok, :error

    one :node, resource: Disk::NodeSerializer
  end
end
