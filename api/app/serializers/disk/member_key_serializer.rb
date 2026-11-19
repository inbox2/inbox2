module Disk
  # A member's X25519 identity public key, for sealing a scope key to them
  # (build guide 7, GET /keys/members). null when they have none.
  class MemberKeySerializer
    include Alba::Resource

    attribute :membership_id, &:key

    attribute :public_key do |m|
      Disk::Sealing.public_key(m)
    end
  end
end
