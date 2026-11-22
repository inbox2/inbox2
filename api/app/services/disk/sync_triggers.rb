module Disk
  # Change tracking for the Disk sync feed (docs/Disk-Sync.md), the Disk
  # counterpart of ::SyncTriggers and built on its sync_stamp() and
  # sync_change_seq, so Disk and MX cursors share one clock.
  #
  #   * disk_sync_stamp     every INSERT/UPDATE on disk_nodes takes a fresh change_seq/change_xid.
  #   * disk_sync_subtree   a node that changes parent re-stamps everything beneath it, so a
  #                         folder moved into view arrives with its contents.
  #   * disk_sync_gone_*    a deleted node, or one moved to another org (C:\ <-> a team share),
  #                         leaves a "deleted" event in the org it left.
  #   * disk_sync_acl_*     a write to grants, share memberships, key grants or shares leaves
  #                         one "acl" event per org it touches; the client then reconciles.
  #                         Grants also name the grantee membership's org (a grant reaches
  #                         another person's C:\, which lives in their personal org).
  #   * disk_sync_share_root a share update re-stamps its root node (share_name lives there).
  #
  # schema.rb cannot express any of this, so ensure! is idempotent and runs from the
  # migration AND after every schema load (config/initializers/sync_triggers.rb).
  # spec/services/disk_sync_triggers_spec.rb fails the suite if they go missing.
  module SyncTriggers
    # table => trigger argument (grantee: also the org of membership_id)
    ACL_TABLES = { "disk_grants" => "grantee", "disk_share_memberships" => "", "disk_key_grants" => "",
                   "disk_shares" => "" }.freeze

    FUNCTIONS = <<~SQL.freeze
      CREATE OR REPLACE FUNCTION disk_sync_subtree() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        UPDATE disk_nodes SET change_seq = change_seq WHERE id IN (
          WITH RECURSIVE t(id) AS (
            SELECT id FROM disk_nodes WHERE parent_id = NEW.id
            UNION ALL
            SELECT n.id FROM disk_nodes n JOIN t ON n.parent_id = t.id
          ) SELECT id FROM t);
        RETURN NULL;
      END $$;

      CREATE OR REPLACE FUNCTION disk_sync_gone() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          INSERT INTO disk_sync_events (organization_id, kind, node_key, change_seq, change_xid, created_at)
          SELECT organization_id, 'deleted', key, nextval('sync_change_seq'), pg_current_xact_id()::text::bigint, now()
          FROM old_rows;
        ELSE
          INSERT INTO disk_sync_events (organization_id, kind, node_key, change_seq, change_xid, created_at)
          SELECT o.organization_id, 'deleted', o.key, nextval('sync_change_seq'), pg_current_xact_id()::text::bigint, now()
          FROM old_rows o JOIN new_rows n ON n.id = o.id WHERE n.organization_id <> o.organization_id;
        END IF;
        RETURN NULL;
      END $$;

      CREATE OR REPLACE FUNCTION disk_sync_acl() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE cols text; src text; orgs text;
      BEGIN
        cols := CASE WHEN TG_ARGV[0] = 'grantee' THEN 'organization_id, membership_id' ELSE 'organization_id' END;
        src := CASE TG_OP
          WHEN 'INSERT' THEN format('SELECT %s FROM new_rows', cols)
          WHEN 'DELETE' THEN format('SELECT %s FROM old_rows', cols)
          ELSE format('SELECT %1$s FROM new_rows UNION ALL SELECT %1$s FROM old_rows', cols)
        END;
        orgs := format('SELECT organization_id AS o FROM (%s) r', src);
        IF TG_ARGV[0] = 'grantee' THEN
          orgs := orgs || format(' UNION SELECT m.organization_id FROM (%s) r JOIN memberships m ON m.id = r.membership_id', src);
        END IF;
        EXECUTE format(
          'INSERT INTO disk_sync_events (organization_id, kind, change_seq, change_xid, created_at)
           SELECT o, ''acl'', nextval(''sync_change_seq''), pg_current_xact_id()::text::bigint, now()
           FROM (SELECT DISTINCT o FROM (%s) x) d', orgs);
        RETURN NULL;
      END $$;
    SQL

    module_function

    def ensure!(conn = ActiveRecord::Base.connection)
      conn.execute(::SyncTriggers::FUNCTIONS) # sync_stamp, sync_bump_parent, sync_change_seq
      conn.execute(FUNCTIONS)
      trigger(conn, "disk_nodes", "disk_sync_stamp", "BEFORE INSERT OR UPDATE ON disk_nodes FOR EACH ROW EXECUTE FUNCTION sync_stamp()")
      trigger(conn, "disk_nodes", "disk_sync_subtree",
        "AFTER UPDATE OF parent_id ON disk_nodes FOR EACH ROW WHEN (OLD.parent_id IS DISTINCT FROM NEW.parent_id) " \
        "EXECUTE FUNCTION disk_sync_subtree()")
      trigger(conn, "disk_nodes", "disk_sync_gone_del",
        "AFTER DELETE ON disk_nodes REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION disk_sync_gone()")
      trigger(conn, "disk_nodes", "disk_sync_gone_upd",
        "AFTER UPDATE ON disk_nodes REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT " \
        "EXECUTE FUNCTION disk_sync_gone()")
      ACL_TABLES.each do |table, arg|
        call = "FOR EACH STATEMENT EXECUTE FUNCTION disk_sync_acl('#{arg}')"
        trigger(conn, table, "disk_sync_acl_ins", "AFTER INSERT ON #{table} REFERENCING NEW TABLE AS new_rows #{call}")
        trigger(conn, table, "disk_sync_acl_upd",
          "AFTER UPDATE ON #{table} REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows #{call}")
        trigger(conn, table, "disk_sync_acl_del", "AFTER DELETE ON #{table} REFERENCING OLD TABLE AS old_rows #{call}")
      end
      trigger(conn, "disk_shares", "disk_sync_share_root",
        "AFTER UPDATE ON disk_shares REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT " \
        "EXECUTE FUNCTION sync_bump_parent('disk_nodes', 'root_node_id')")
    end

    # The trigger names ensure! installs, for the tripwire spec.
    def names
      %w[disk_sync_stamp disk_sync_subtree disk_sync_gone_del disk_sync_gone_upd disk_sync_share_root] +
        %w[ins upd del].map { |op| "disk_sync_acl_#{op}" } * ACL_TABLES.size
    end

    def remove!(conn = ActiveRecord::Base.connection)
      %w[disk_sync_stamp disk_sync_subtree disk_sync_gone_del disk_sync_gone_upd].each do |t|
        conn.execute("DROP TRIGGER IF EXISTS #{t} ON disk_nodes;")
      end
      ACL_TABLES.each_key { |t| %w[ins upd del].each { |op| conn.execute("DROP TRIGGER IF EXISTS disk_sync_acl_#{op} ON #{t};") } }
      conn.execute("DROP TRIGGER IF EXISTS disk_sync_share_root ON disk_shares;")
      conn.execute("DROP FUNCTION IF EXISTS disk_sync_subtree(), disk_sync_gone(), disk_sync_acl();")
    end

    def trigger(conn, table, name, body)
      conn.execute("DROP TRIGGER IF EXISTS #{name} ON #{table}; CREATE TRIGGER #{name} #{body};")
    end
  end
end
