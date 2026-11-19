module Disk
  # One page of the org export (Disk::Export). The manifest comes with the
  # first page only.
  class ExportSerializer
    include Alba::Resource

    Page = Struct.new(:manifest, :entries, :next_cursor, keyword_init: true)

    attribute :manifest do |p|
      m = p.manifest
      next nil unless m

      { generated_at: m.generated_at, note: m.note, totals: m.totals,
        members: m.members.map { |mb| Disk::MemberRefSerializer.new(mb).to_h.merge(role: mb.role) },
        shares: m.shares.map do |s|
          Disk::ShareSerializer.new(s).to_h.merge(
            folder: "D/#{s.name.tr('/\\', '__')}",
            members: Disk::ShareMemberSerializer.new(m.share_members[s.id] || []).to_h
          )
        end,
        grants: m.grants.map { |g| Disk::GrantSerializer.new(g).to_h.merge(path: m.paths[g.node_id]) },
        links: m.links.map { |l| Disk::LinkSerializer.new(l).to_h.merge(path: m.paths[l.node_id]) } }
    end

    attribute :entries do |p|
      p.entries.map do |e|
        n = e.node
        { id: n.key, kind: n.kind, path: e.path, sealed: n.sealed?, included: !n.sealed?,
          size_bytes: n.page? ? e.markdown.to_s.bytesize : n.size_bytes, mime: n.sealed? ? nil : n.mime,
          url: e.url, expires_at: e.expires_at, markdown: e.markdown, scope_id: e.scope_key }
      end
    end

    attributes :next_cursor
  end
end
