# Address folders: the shared addresses on a domain (info@, support@) and each
# member's folder settings (Show in Inbox, the bell), keyed by full address.
class AddAddressFolders < ActiveRecord::Migration[8.1]
  def change
    add_column :domains, :shared_addresses, :jsonb, default: [], null: false, if_not_exists: true
    add_column :memberships, :folder_prefs, :jsonb, default: {}, null: false, if_not_exists: true
  end
end
