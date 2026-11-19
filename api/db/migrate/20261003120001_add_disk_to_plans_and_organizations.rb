# Disk (docs/plans/disk-build.md section 4): the plan gate and the org's pooled
# quota figures. Additive columns with constant defaults only, so this is a
# metadata-only change on a live database.
class AddDiskToPlansAndOrganizations < ActiveRecord::Migration[8.1]
  def change
    add_column :plans, :disk, :boolean, null: false, default: false, if_not_exists: true
    add_column :plans, :disk_gb_per_member, :integer, null: false, default: 0, if_not_exists: true

    add_column :organizations, :disk_bytes_used, :bigint, null: false, default: 0, if_not_exists: true
    add_column :organizations, :disk_bytes_reserved, :bigint, null: false, default: 0, if_not_exists: true
    add_column :organizations, :disk_quota_override_gb, :integer, if_not_exists: true
    add_column :organizations, :disk_links_enabled, :boolean, null: false, default: true, if_not_exists: true
    add_column :organizations, :disk_lost_at, :datetime, if_not_exists: true
    add_column :organizations, :disk_quota_notified_level, :integer, null: false, default: 0, if_not_exists: true
  end
end
