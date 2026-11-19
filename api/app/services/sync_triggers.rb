# Change tracking for the MX sync protocol (docs/MX-Sync.md).
#
# Lives in Postgres, not in model callbacks: the bulk endpoint, merge, membership
# suspend and the GDPR scrub all write with `update_all`, which callbacks never
# see — and bulk archive is the single most common triage action.
#
#   * `sync_stamp`        — every INSERT/UPDATE on a synced table takes a fresh
#                           `change_seq` (the row's version) and records the
#                           writing transaction in `change_xid` (what the pull
#                           cursor walks; see SyncController).
#   * `sync_bump_parent`  — a child write re-stamps its parent, so
#                           `conversations.change_seq` is the *thread* version.
#                           Statement-level over transition tables: a 10k-row
#                           `update_all` bumps each distinct parent once.
#   * `sync_tombstone`    — deletes leave a row in `sync_tombstones`.
#
# schema.rb cannot express any of this, so `ensure!` is idempotent and runs from
# the migration AND after every schema load (config/initializers/sync_triggers.rb).
# spec/services/sync_triggers_spec.rb fails the suite if they go missing.
module SyncTriggers
  # table => tombstone record_type
  STAMPED = { "conversations" => "conversation", "messages" => "message", "notes" => "note" }.freeze
  THREAD_KEY = "(SELECT c.key FROM conversations c WHERE c.id = old_rows.conversation_id)".freeze
  # table => SQL for the tombstone's parent_key
  PARENT_KEY = { "conversations" => "NULL", "messages" => THREAD_KEY, "notes" => THREAD_KEY }.freeze

  # [child, parent, fk]
  BUMPS = [
    %w[messages conversations conversation_id],
    %w[notes conversations conversation_id],
    %w[conversation_tags conversations conversation_id],
    %w[conversation_assignees conversations conversation_id],
    %w[conversation_accesses conversations conversation_id],
    %w[lore_member_dones conversations conversation_id],
    %w[attachments messages message_id],
    %w[note_reactions notes note_id]
  ].freeze

  FUNCTIONS = <<~SQL.freeze
    CREATE SEQUENCE IF NOT EXISTS sync_change_seq;

    CREATE OR REPLACE FUNCTION sync_stamp() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      NEW.change_seq := nextval('sync_change_seq');
      NEW.change_xid := pg_current_xact_id()::text::bigint;
      RETURN NEW;
    END $$;

    -- TG_ARGV: parent table, fk column. The UPDATE is a no-op write whose only
    -- job is to fire the parent's sync_stamp; a parent already deleted in this
    -- transaction simply matches no rows.
    CREATE OR REPLACE FUNCTION sync_bump_parent() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE src text;
    BEGIN
      src := CASE TG_OP
        WHEN 'INSERT' THEN format('SELECT %1$I FROM new_rows', TG_ARGV[1])
        WHEN 'DELETE' THEN format('SELECT %1$I FROM old_rows', TG_ARGV[1])
        ELSE format('SELECT %1$I FROM new_rows UNION SELECT %1$I FROM old_rows', TG_ARGV[1])
      END;
      -- Lock in id order first: two bulk child writes over overlapping parents
      -- would otherwise take the parent row locks in opposite orders and deadlock.
      -- NO KEY UPDATE, exactly what the UPDATE below needs: plain FOR UPDATE also
      -- conflicts with the KEY SHARE lock every child insert holds on its parent
      -- (the FK check), which manufactures wait cycles of its own.
      EXECUTE format('SELECT 1 FROM %I WHERE id IN (%s) ORDER BY id FOR NO KEY UPDATE', TG_ARGV[0], src);
      EXECUTE format('UPDATE %I SET change_seq = change_seq WHERE id IN (%s)', TG_ARGV[0], src);
      RETURN NULL;
    END $$;

    -- TG_ARGV: record_type, parent-key expression. `parent_key` is the thread a
    -- deleted message/note belonged to, so a pull can re-apply visibility to it
    -- (Rails destroys children before the parent, so the thread still exists here).
    CREATE OR REPLACE FUNCTION sync_tombstone() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      EXECUTE format(
        'INSERT INTO sync_tombstones (organization_id, record_type, record_key, parent_key, change_seq, change_xid, created_at)
         SELECT organization_id, %L, key, %s, nextval(''sync_change_seq''), pg_current_xact_id()::text::bigint, now()
         FROM old_rows', TG_ARGV[0], TG_ARGV[1]);
      RETURN NULL;
    END $$;
  SQL

  module_function

  def ensure!(conn = ActiveRecord::Base.connection)
    conn.execute(FUNCTIONS)
    STAMPED.each do |table, type|
      trigger(conn, table, "sync_stamp", "BEFORE INSERT OR UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION sync_stamp()")
      trigger(conn, table, "sync_tombstone",
        "AFTER DELETE ON #{table} REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT " \
        "EXECUTE FUNCTION sync_tombstone('#{type}', #{conn.quote(PARENT_KEY.fetch(table))})")
    end
    BUMPS.each do |child, parent, fk|
      call = "FOR EACH STATEMENT EXECUTE FUNCTION sync_bump_parent('#{parent}', '#{fk}')"
      trigger(conn, child, "sync_bump_ins", "AFTER INSERT ON #{child} REFERENCING NEW TABLE AS new_rows #{call}")
      trigger(conn, child, "sync_bump_upd",
        "AFTER UPDATE ON #{child} REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows #{call}")
      trigger(conn, child, "sync_bump_del", "AFTER DELETE ON #{child} REFERENCING OLD TABLE AS old_rows #{call}")
    end
  end

  def remove!(conn = ActiveRecord::Base.connection)
    STAMPED.each_key { |t| conn.execute("DROP TRIGGER IF EXISTS sync_stamp ON #{t}; DROP TRIGGER IF EXISTS sync_tombstone ON #{t};") }
    BUMPS.each { |child, _, _| %w[ins upd del].each { |op| conn.execute("DROP TRIGGER IF EXISTS sync_bump_#{op} ON #{child};") } }
    conn.execute("DROP FUNCTION IF EXISTS sync_stamp(), sync_bump_parent(), sync_tombstone(); DROP SEQUENCE IF EXISTS sync_change_seq;")
  end

  def trigger(conn, table, name, body)
    conn.execute("DROP TRIGGER IF EXISTS #{name} ON #{table}; CREATE TRIGGER #{name} #{body};")
  end
end
