module Disk
  # One person on a node's Access column: who, their avatar, their role there.
  # params: org_key (the avatar URL's org context).
  class GrantRefSerializer
    include Alba::Resource

    attributes :role

    attribute :membership_id do |g|
      g.membership.key
    end

    attribute :name do |g|
      g.membership.user.display_name.presence || g.membership.user.username
    end

    attribute :avatar_url do |g|
      user = g.membership.user
      next nil if user.avatar_url.blank?

      user.avatar_url.start_with?("http") ? user.avatar_url : UserSerializer.avatar_url(user, org_key: params[:org_key])
    end
  end
end
