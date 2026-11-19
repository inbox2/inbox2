# Shares appear in Disk URLs by slug (/:org/disk/d/<share-slug>/...): derived
# from the name, unique per org among live shares, kept on rename.
class AddSlugToDiskShares < ActiveRecord::Migration[8.1]
  # A bare model for this migration only, never fed request params (strong
  # parameters replaced attr_accessible).
  class Share < ActiveRecord::Base # nosemgrep: ruby.lang.security.model-attributes-attr-accessible
    self.table_name = "disk_shares"
  end

  def up
    add_column :disk_shares, :slug, :string, if_not_exists: true
    Share.where(slug: nil).order(:id).each do |share|
      base = share.name.to_s.parameterize.presence || "share"
      taken = Share.where(organization_id: share.organization_id, trashed_at: nil).where.not(id: share.id).pluck(:slug)
      slug = base
      n = 1
      slug = "#{base}-#{n += 1}" while taken.include?(slug)
      share.update_columns(slug: slug)
    end
    add_index :disk_shares, %i[organization_id slug], unique: true, where: "trashed_at IS NULL",
                                                       name: "index_disk_shares_on_org_and_slug", if_not_exists: true
  end

  def down
    remove_index :disk_shares, name: "index_disk_shares_on_org_and_slug", if_exists: true
    remove_column :disk_shares, :slug, if_exists: true
  end
end
