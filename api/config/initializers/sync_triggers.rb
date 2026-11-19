# schema.rb can't carry the MX sync triggers (docs/MX-Sync.md), so reinstall them
# whenever a schema file is loaded — db:schema:load, db:test:prepare, and the
# fresh-database branch of db:prepare all go through DatabaseTasks.load_schema.
# `load_schema` is :nodoc: API; spec/services/sync_triggers_spec.rb is the tripwire
# if a Rails upgrade moves it.
ActiveSupport.on_load(:active_record) do
  ActiveRecord::Tasks::DatabaseTasks.singleton_class.prepend(Module.new do
    def load_schema(*)
      super
      # schema.rb was just `load`ed over this same connection.
      conn = ActiveRecord::Base.lease_connection
      SyncTriggers.ensure!(conn) if conn.table_exists?("sync_tombstones")
    end
  end)
end
