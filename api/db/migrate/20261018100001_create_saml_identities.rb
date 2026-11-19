# Code audit 2026-10-18 (TODO 47.2): SAML used to resolve the signed-in user by
# the NameID's local-part against usernames, so an org admin running their own
# IdP could mint the owner's session. Identities are now explicit rows: an
# existing member links theirs once while signed in; first-time SSO users are
# provisioned; nothing is ever matched by name.
class CreateSamlIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :saml_identities, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.bigint :user_id, null: false
      t.string :name_id, null: false
      t.datetime :last_login_at
      t.timestamps
    end
    add_index :saml_identities, :key, unique: true, if_not_exists: true
    add_index :saml_identities, %i[organization_id name_id], unique: true, if_not_exists: true
    add_index :saml_identities, :user_id, if_not_exists: true
    add_foreign_key :saml_identities, :organizations, on_delete: :cascade unless foreign_key_exists?(:saml_identities, :organizations)
    add_foreign_key :saml_identities, :users, on_delete: :cascade unless foreign_key_exists?(:saml_identities, :users)
  end
end
