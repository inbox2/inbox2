# Every part number the API presigned for an upload. Completion refuses a part
# storage holds that was never issued here (docs/plans/disk-build.md section 8).
class CreateDiskUploadParts < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_upload_parts, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.bigint :upload_id, null: false
      t.integer :number, null: false
      t.datetime :issued_at, null: false
      t.index %i[upload_id number], unique: true
    end
    add_foreign_key :disk_upload_parts, :organizations, if_not_exists: true
    add_foreign_key :disk_upload_parts, :disk_uploads, column: :upload_id, on_delete: :cascade, if_not_exists: true
  end
end
