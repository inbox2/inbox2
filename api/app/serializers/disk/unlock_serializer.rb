module Disk
  # Proof that a link's password was given: send it back as X-Disk-Link-Unlock.
  class UnlockSerializer
    include Alba::Resource

    Unlock = Struct.new(:token, :expires_at, keyword_init: true)

    attributes :token, :expires_at
  end
end
