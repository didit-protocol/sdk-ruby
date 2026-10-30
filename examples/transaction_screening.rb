# frozen_string_literal: true

# Transaction monitoring: submit a transaction for screening, then list recent ones.
#
#   export DIDIT_API_KEY=...
#   ruby -Ilib examples/transaction_screening.rb

require "didit"
require "securerandom"

didit = Didit::Client.new
transaction = didit.transactions.create(
  transaction_id: "order-#{SecureRandom.hex(4)}",
  transaction_category: "finance",
  transaction_details: { direction: "outbound", amount: 1500, currency: "EUR", action_type: "withdrawal" },
  subject: { entity_type: "individual", vendor_data: "user-42", full_name: "Maria Garcia" }
)
puts "Transaction #{transaction.txn_id}: #{transaction.status}, #{transaction.amount} #{transaction.currency}"

# Every page, fetched as needed.
didit.transactions.list(limit: 50).auto_paging_each.first(10).each do |item|
  puts "- #{item.txn_id} #{item.status}"
end
