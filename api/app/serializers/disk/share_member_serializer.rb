module Disk
  class ShareMemberSerializer
    include Alba::Resource

    attributes :role

    attribute :membership_id do |sm|
      sm.membership.key
    end

    attribute :name do |sm|
      sm.membership.user.display_name.presence || sm.membership.user.username
    end
  end
end
