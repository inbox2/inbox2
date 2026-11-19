module Disk
  # In-app URLs for Disk items, the scheme the web client routes (no org in
  # the path since 2026-10-04: Disk works on one org at a time, and a client
  # whose current org lacks the id tries the person's other orgs):
  #   /disk/d/<share-slug>/Brand/Logos-<short_id>   in a share: the viewer's drive letter for that team
  #                                                  (D:, E:, F: ... per membership, 2026-10-07), d when unknown
  #   /disk/c/Clients/Invoices-<short_id>            on C:\
  #   /disk/shared/<name>-<short_id>                 when the viewer cannot see the way down from the root
  # The client resolves the item by its short id and corrects the rest.
  module WebPath
    module_function

    def for(node, viewer: nil)
      base = "/disk"
      chain = node.path
      if viewer
        seen = Disk::Access.scope_for(viewer).where(id: chain.map(&:id)).pluck(:id).to_set
        chain = chain.select { |n| seen.include?(n.id) }
      end
      unless chain.first&.root?
        # Shared with me carries no drive to name the org; ?org= picks it (a team org; C:\ is reached without one).
        org = node.organization
        return "#{base}/shared/#{segment(node)}-#{node.short_id}#{"?org=#{org.slug || org.key}" unless org.personal?}"
      end

      root = chain.first
      letter = (viewer&.drive_letter || Membership::FIRST_DRIVE_LETTER).downcase
      head = root.on_c_drive? ? "#{base}/c" : "#{base}/#{letter}/#{root.share.slug}"
      return head if node.root?

      [head, *chain[1...-1].map { |n| segment(n) }, "#{segment(node)}-#{node.short_id}"].join("/")
    end

    # Disk itself in one org (its slug, or key when it has none), for messages
    # about the org rather than an item: ?org= selects it in the client.
    def org_home(org_ref, page = nil) = "/disk#{page && "/#{page}"}?org=#{ERB::Util.url_encode(org_ref)}"

    # An absolute link to an in-app path (from #for or #org_home). With DISK_APP_URL
    # (https://disk.inbox2.com) Disk has its own host and sits at its root:
    # /disk/c/... becomes <DISK_APP_URL>/c/.... Without it, <WEB_APP_URL>/disk/....
    # In-app notifications keep the /disk/... path: the client drops the prefix on the disk host.
    def url(path)
      return "#{web_app_url}#{path}" if disk_app_url.blank?

      "#{disk_app_url}#{path.delete_prefix('/disk').then { |p| p.start_with?('/') ? p : "/#{p}" }}"
    end

    def web_app_url = ENV.fetch("WEB_APP_URL", "https://app.inbox2.com").chomp("/")
    def disk_app_url = ENV["DISK_APP_URL"].to_s.chomp("/")

    def segment(node) = ERB::Util.url_encode(node.sealed? ? node.short_id : node.name.to_s)

    # The public link page: <DISK_APP_URL or WEB_APP_URL>/share/<name-slug>/<token>. A sealed
    # file's link has no name in it (build guide 6.9): /share/<token>, to which
    # the client appends #<secret>.
    def public_link(node, token)
      base = "#{disk_app_url.presence || web_app_url}/share"
      return "#{base}/#{token}" if node.sealed?

      "#{base}/#{node.name.to_s.parameterize.presence || 'item'}/#{token}"
    end
  end
end
