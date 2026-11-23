# Domain signatures: an admin sets one signature for every address on a domain.
class AddDomainToSignatures < ActiveRecord::Migration[8.1]
  def change
    add_column :signatures, :domain_id, :bigint, if_not_exists: true
    add_index :signatures, :domain_id, if_not_exists: true
    add_foreign_key :signatures, :domains, on_delete: :cascade, if_not_exists: true
  end
end
