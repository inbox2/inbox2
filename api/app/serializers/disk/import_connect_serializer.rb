module Disk
  # The consent URL POST /imports/:provider/connect answers with.
  class ImportConnectSerializer
    include Alba::Resource

    Connect = Struct.new(:authorize_url, keyword_init: true)

    attributes :authorize_url
  end
end
