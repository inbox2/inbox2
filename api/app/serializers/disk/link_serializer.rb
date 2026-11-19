module Disk
  # A public link as its managers see it. The token exists only in the create
  # response (params[:token]); afterwards the server holds just its digest.
  class LinkSerializer < ::ApplicationSerializer
    attributes :expires_at, :hide_download, :revoked_at, :last_used_at, :created_at

    attribute :node_id do |l|
      l.node.key
    end

    attribute :has_password, &:password?
    attribute :expired, &:expired?

    attribute :token do |_l|
      params[:token]
    end

    attribute :url do |l|
      params[:token] && Disk::WebPath.public_link(l.node, params[:token])
    end

    # A sealed file link (build guide 6.9): the version it is pinned to.
    attribute :sealed, &:sealed?

    attribute :version_id do |l|
      l.version&.key
    end

    one :created_by, resource: Disk::MemberRefSerializer
  end
end
