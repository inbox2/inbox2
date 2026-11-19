module Disk
  # The console's usage report (GET /admin/usage): the org meter, bytes per
  # member's C:\ and per share (every version, current, old and trashed, as
  # the meter counts them), and the settings an admin changes.
  class UsageSerializer
    include Alba::Resource

    Usage = Struct.new(:organization, :quota, :members, :shares, keyword_init: true)
    Row = Struct.new(:membership, :share, :bytes, :member_count, keyword_init: true)

    attribute :quota do |u|
      Disk::QuotaSerializer.new(u.quota).to_h
    end

    attribute :quota_override_gb do |u|
      u.organization.disk_quota_override_gb
    end

    attribute :settings do |u|
      Disk::SettingsSerializer.new(u.organization).to_h
    end

    attribute :members do |u|
      u.members.map { |r| { member: Disk::MemberRefSerializer.new(r.membership).to_h, bytes: r.bytes } }
    end

    attribute :shares do |u|
      u.shares.map do |r|
        { share: Disk::ShareSerializer.new(r.share, params: { member_counts: { r.share.id => r.member_count } }).to_h,
          bytes: r.bytes }
      end
    end
  end
end
