module Disk
  # One entry in a page's history. params[:content] adds its ydoc and
  # markdown, or for a sealed page its snapshot (build guide 6.10).
  class PageVersionSerializer
    include Alba::Resource

    attributes :revision, :created_at, :updated_at

    attribute :size_bytes do |v|
      v.sealed_snapshot ? v.sealed_snapshot.bytesize : v.markdown.to_s.bytesize
    end

    attributes :snapshot_epoch, :snapshot_seq

    attribute :sealed_snapshot do |v|
      params[:content] && v.sealed_snapshot ? Base64.strict_encode64(v.sealed_snapshot) : nil
    end

    attribute :markdown do |v|
      params[:content] ? v.markdown : nil
    end

    attribute :ydoc do |v|
      params[:content] && v.ydoc ? Base64.strict_encode64(v.ydoc) : nil
    end

    one :author, resource: Disk::MemberRefSerializer
  end
end
