# Organisation data export (spec 11.3.3, A15.6): one row per requested .zip of
# the org's mail (mbox per domain) and calendars (.ics). The file lives in
# object storage under `storage_key`; the row expires 7 days after it's ready.
class CreateDataExports < ActiveRecord::Migration[8.1]
  def change
    create_table :data_exports, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.bigint :requested_by_membership_id
      t.string :status, null: false, default: "queued"
      t.string :storage_key
      t.bigint :byte_size
      t.jsonb :counts, null: false, default: {}
      t.text :error
      t.datetime :expires_at
      t.timestamps
      t.index :key, unique: true
      t.index %i[organization_id created_at], name: "index_data_exports_on_org_and_created"
      # One export in flight per org, enforced by the database.
      t.index :organization_id, unique: true, where: "status IN ('queued', 'running')",
                                name: "index_data_exports_one_active_per_org"
    end
    add_foreign_key :data_exports, :organizations, if_not_exists: true
    add_foreign_key :data_exports, :memberships, column: :requested_by_membership_id,
                                                 on_delete: :nullify, if_not_exists: true
  end
end
