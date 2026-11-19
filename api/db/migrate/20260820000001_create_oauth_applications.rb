# Registered third-party applications that broker provider OAuth through inbox2
# (docs/App-OAuth.md).
#
# `oauth_apps` is what an org admin registers in the console: a name, an icon and
# the whitelist of redirect URLs the finished flow may bounce back to (one per
# environment — test, staging, production).
#
# `oauth_grants` is one in-flight authorization: created when the app's server
# starts a flow, carried through the consent page and the provider round-trip as
# the OAuth `state`, and consumed when the app redeems the provider tokens. The
# tokens live encrypted on the row for the few minutes between the provider
# callback and redemption.
#
# Its own file so production actually migrates: prod already recorded
# 20260522000001, so folding this into the initial schema would never reach it.
# Both are ALSO in the initial schema so a fresh install still gets everything
# from one file; `if_not_exists` makes this a no-op there.
class CreateOauthApplications < ActiveRecord::Migration[8.1]
  def change
    create_table :oauth_apps, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.bigint :created_by_id
      t.string :name, null: false
      # Internal S3 storage key — streamed through the public icon endpoint.
      t.string :icon_url
      # Exact-match whitelist. An array (not one column) because a single app
      # runs in several environments and each needs its own callback.
      t.jsonb :redirect_uris, null: false, default: []
      t.timestamps
      t.index :key, unique: true, name: "index_oauth_apps_on_key"
      t.index %i[organization_id name], unique: true, name: "index_oauth_apps_on_organization_id_and_name"
    end

    create_table :oauth_grants, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :oauth_app_id, null: false
      t.string :provider, null: false
      t.string :status, null: false, default: "pending"
      # Where the finished flow returns the user (one of the app's whitelisted URLs).
      t.string :redirect_uri, null: false
      # The calling app's own CSRF value, echoed back verbatim on the return trip.
      t.string :client_state
      # The exact redirect_uri handed to the provider — the token exchange must
      # replay the same string, and it depends on which host served the flow.
      t.string :callback_uri
      t.datetime :expires_at, null: false
      t.string :email
      t.text :access_token
      t.text :refresh_token
      t.datetime :token_expires_at
      t.text :scope
      t.timestamps
      t.index :key, unique: true, name: "index_oauth_grants_on_key"
      t.index :oauth_app_id, name: "index_oauth_grants_on_oauth_app_id"
    end

    add_foreign_key :oauth_apps, :organizations, if_not_exists: true
    add_foreign_key :oauth_apps, :users, column: :created_by_id, if_not_exists: true
    add_foreign_key :oauth_grants, :oauth_apps, if_not_exists: true
  end
end
