# Jev files mail into a Space by its description (docs/Triage.md). The default
# Spaces were seeded with none, so Jev only saw the bare name. Fill in the
# canonical wording where an org left a default Space untouched (no description,
# no not_for); anything an org wrote itself is kept. Data only — idempotent, no schema change.
class DescribeDefaultSpaces < ActiveRecord::Migration[8.1]
  def up
    Space::DEFAULT_SPACES.each do |data|
      next if data[:description].blank?

      execute(<<~SQL)
        UPDATE spaces
        SET description = #{connection.quote(data[:description])},
            not_for = #{connection.quote(data[:not_for])}
        WHERE slug = #{connection.quote(data[:slug])}
          AND (description IS NULL OR description = '')
          AND (not_for IS NULL OR not_for = '')
      SQL
    end
  end

  def down; end
end
