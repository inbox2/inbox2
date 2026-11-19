module Disk
  # A stored sealed page update (build guide 6.10).
  class PageUpdateSerializer
    include Alba::Resource

    attributes :seq, :epoch

    attribute :ciphertext do |u|
      Base64.strict_encode64(u.ciphertext)
    end
  end
end
