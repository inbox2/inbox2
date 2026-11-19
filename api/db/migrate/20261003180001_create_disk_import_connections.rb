# A read-only authorisation to a Disk import source (Google Drive, Microsoft
# 365, Dropbox), per member per provider and per reach: "member" for the
# member's own drive, "org" for an owner's or admin's org-wide grant. Kept
# apart from mail channels and conferencing grants (build guide 9b).
class CreateDiskImportConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_import_connections, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.bigint :membership_id, null: false
      t.string :provider, null: false
      t.string :reach, null: false
      t.string :account_email
      t.string :tenant
      t.text :refresh_token
      t.text :access_token
      t.datetime :access_expires_at
      t.datetime :throttled_until
      t.timestamps
      t.index %i[membership_id provider reach], unique: true, name: "index_disk_import_connections_unique"
      t.index %i[provider tenant]
    end
    add_foreign_key :disk_import_connections, :organizations, if_not_exists: true
    add_foreign_key :disk_import_connections, :memberships, on_delete: :cascade, if_not_exists: true
  end
end
