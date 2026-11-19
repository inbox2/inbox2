# Shared role addresses on a domain (info, sales, support…): local parts every
# member who can see the domain's pool may send as (Membership#can_send_as?).
class AddSharedAddressesToDomains < ActiveRecord::Migration[8.1]
  def change
    add_column :domains, :shared_addresses, :string, array: true, default: [], null: false, if_not_exists: true
  end
end
