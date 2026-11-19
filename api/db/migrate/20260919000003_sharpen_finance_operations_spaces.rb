# Operations was pulling in tax, VAT, budget and revenue-recognition threads
# that belong in Finance: its not_for only fenced off invoices and payments.
# Re-word both default Spaces wherever an org still carries the text seeded by
# 20260919000002 (anything an org wrote itself is kept). Data only.
class SharpenFinanceOperationsSpaces < ActiveRecord::Migration[8.1]
  OLD_FINANCE_DESCRIPTION = "Money matters: invoices, bills, payments, receipts, taxes, accounting and expenses".freeze
  OLD_OPERATIONS_NOT_FOR = "Customer questions; invoices and payments".freeze

  def up
    finance = Space::DEFAULT_SPACES.find { |s| s[:slug] == "finance" }
    operations = Space::DEFAULT_SPACES.find { |s| s[:slug] == "operations" }

    execute(<<~SQL)
      UPDATE spaces SET description = #{connection.quote(finance[:description])}
      WHERE slug = 'finance' AND description = #{connection.quote(OLD_FINANCE_DESCRIPTION)}
    SQL
    execute(<<~SQL)
      UPDATE spaces SET not_for = #{connection.quote(operations[:not_for])}
      WHERE slug = 'operations' AND not_for = #{connection.quote(OLD_OPERATIONS_NOT_FOR)}
    SQL
  end

  def down; end
end
