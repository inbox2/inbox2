# C:\ is the person's, not an org's (decided 2026-10-07): it lives in a hidden
# personal workspace organization (organizations.personal_user_id), one per
# user, that no org list shows and that nobody can leave. The custodian of every
# C:\ node is the user's membership of that workspace. Each team membership gets
# a drive letter (D:, E:, F: ...) in the order the person joined.
class PersonalDiskAndDriveLetters < ActiveRecord::Migration[8.1]
  def up
    add_column :organizations, :personal_user_id, :bigint, if_not_exists: true
    add_index :organizations, :personal_user_id, unique: true, if_not_exists: true
    unless foreign_key_exists?(:organizations, :users, column: :personal_user_id)
      add_foreign_key :organizations, :users, column: :personal_user_id, on_delete: :cascade
    end
    add_column :memberships, :drive_letter, :string, limit: 1, if_not_exists: true

    move_c_drives!
    assign_letters!
  end

  def down
    remove_column :memberships, :drive_letter, if_exists: true
    remove_column :organizations, :personal_user_id, if_exists: true
  end

  private

  # Every existing C:\ root moves into its custodian's personal workspace. A
  # person with files on C:\ in several orgs gets the first as their C:\ and the
  # others' contents under a folder named after that org. Quota figures follow.
  def move_c_drives!
    roots = select_all(<<~SQL)
      SELECT n.id, n.organization_id, m.user_id, o.name AS org_name
      FROM disk_nodes n
      JOIN memberships m ON m.id = n.custodian_membership_id
      JOIN organizations o ON o.id = n.organization_id
      WHERE n.parent_id IS NULL AND n.custodian_membership_id IS NOT NULL AND o.personal_user_id IS NULL
      ORDER BY m.user_id, n.id
    SQL
    roots.group_by { |r| r["user_id"] }.each do |user_id, rs|
      personal_id, membership_id = personal_workspace!(user_id)
      first, *others = rs
      rehome!(first["id"], first["organization_id"], personal_id, membership_id)
      others.each do |r|
        folder_id = select_value(<<~SQL)
          INSERT INTO disk_nodes (key, organization_id, custodian_membership_id, parent_id, kind, name,
                                  created_at, updated_at, content_modified_at)
          VALUES (#{quote("dnd_#{Nanoid.generate(size: 21)}")}, #{personal_id}, #{membership_id}, #{first['id']},
                  'folder', #{quote(r['org_name'])}, now(), now(), now())
          RETURNING id
        SQL
        execute("UPDATE disk_nodes SET parent_id = #{folder_id} WHERE parent_id = #{r['id']}")
        execute("DELETE FROM disk_nodes WHERE id = #{r['id']}") # the old root first: one root per custodian
        rehome!(folder_id, r["organization_id"], personal_id, membership_id)
        execute("UPDATE disk_nodes SET size_bytes = (SELECT COALESCE(SUM(size_bytes), 0) FROM disk_nodes WHERE parent_id = #{folder_id}) WHERE id = #{folder_id}")
        execute("UPDATE disk_nodes SET size_bytes = (SELECT COALESCE(SUM(size_bytes), 0) FROM disk_nodes WHERE parent_id = #{first['id']}) WHERE id = #{first['id']}")
      end
    end
  end

  def personal_workspace!(user_id)
    org_id = select_value("SELECT id FROM organizations WHERE personal_user_id = #{user_id}")
    org_id ||= select_value(<<~SQL)
      INSERT INTO organizations (key, name, slug, owner_id, personal_user_id, created_at, updated_at)
      VALUES (#{quote("org_#{Nanoid.generate(size: 21)}")}, 'My disk', #{quote("personal-#{Nanoid.generate(size: 12).downcase}")},
              #{user_id}, #{user_id}, now(), now())
      RETURNING id
    SQL
    membership_id = select_value("SELECT id FROM memberships WHERE organization_id = #{org_id} AND user_id = #{user_id}")
    membership_id ||= select_value(<<~SQL)
      INSERT INTO memberships (key, organization_id, user_id, role, status, member_type, created_at, updated_at)
      VALUES (#{quote("mem_#{Nanoid.generate(size: 21)}")}, #{org_id}, #{user_id}, 'owner', 'active', 'human', now(), now())
      RETURNING id
    SQL
    [org_id, membership_id]
  end

  # Moves a root's subtree (nodes and the rows that carry its org) into the
  # personal workspace, and its bytes from the old org's quota to the new one.
  def rehome!(root_id, from_org, to_org, custodian_id)
    subtree = "WITH RECURSIVE t AS (SELECT id FROM disk_nodes WHERE id = #{root_id} " \
              "UNION ALL SELECT n.id FROM disk_nodes n JOIN t ON n.parent_id = t.id) SELECT id FROM t"
    bytes = select_value("SELECT COALESCE(SUM(size_bytes), 0) FROM disk_versions WHERE node_id IN (#{subtree})").to_i
    %w[disk_versions disk_stars disk_grants disk_agent_grants disk_links disk_pages disk_page_versions disk_page_updates
       disk_recents disk_events].each do |table|
      execute("UPDATE #{table} SET organization_id = #{to_org} WHERE node_id IN (#{subtree})")
    end
    %w[disk_key_grants disk_scope_epochs].each do |table|
      execute("UPDATE #{table} SET organization_id = #{to_org} WHERE scope_node_id IN (#{subtree})")
    end
    execute("UPDATE disk_nodes SET organization_id = #{to_org}, custodian_membership_id = #{custodian_id} WHERE id IN (#{subtree})")
    execute("UPDATE organizations SET disk_bytes_used = GREATEST(disk_bytes_used - #{bytes}, 0) WHERE id = #{from_org}")
    execute("UPDATE organizations SET disk_bytes_used = disk_bytes_used + #{bytes} WHERE id = #{to_org}")
  end

  # D:, E:, F: ... per person, in the order they joined their teams.
  def assign_letters!
    rows = select_all(<<~SQL)
      SELECT m.id, m.user_id FROM memberships m
      JOIN organizations o ON o.id = m.organization_id
      WHERE o.personal_user_id IS NULL AND m.member_type = 'human'
      ORDER BY m.user_id, m.created_at, m.id
    SQL
    rows.group_by { |r| r["user_id"] }.each_value do |ms|
      ms.each_with_index do |m, i|
        letter = ("D".ord + i).chr
        next if letter > "Z"

        execute("UPDATE memberships SET drive_letter = #{quote(letter)} WHERE id = #{m['id']}")
      end
    end
  end
end
