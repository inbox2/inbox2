# Disk shares belong to a team (2026-10-04): an org is one payer with several
# distinct companies, one per domain. A share with a domain is open only to
# members who see that domain (Membership#accessible_domain_ids), and share
# names are unique per team, not per org. No domain: the whole organization.
class AddDomainToDiskShares < ActiveRecord::Migration[8.1]
  def up
    add_column :disk_shares, :domain_id, :bigint, if_not_exists: true
    add_index :disk_shares, :domain_id, if_not_exists: true
    unless foreign_key_exists?(:disk_shares, :domains)
      add_foreign_key :disk_shares, :domains, column: :domain_id, on_delete: :nullify
    end
    remove_index :disk_shares, name: "index_disk_shares_on_org_and_lower_name", if_exists: true
    add_index :disk_shares, "organization_id, COALESCE(domain_id, 0), lower((name)::text)",
              name: "index_disk_shares_on_org_domain_and_lower_name", unique: true, where: "(trashed_at IS NULL)",
              if_not_exists: true
  end

  def down
    remove_index :disk_shares, name: "index_disk_shares_on_org_domain_and_lower_name", if_exists: true
    add_index :disk_shares, "organization_id, lower((name)::text)", name: "index_disk_shares_on_org_and_lower_name",
                                                                   unique: true, where: "(trashed_at IS NULL)", if_not_exists: true
    remove_column :disk_shares, :domain_id, if_exists: true
  end
end
