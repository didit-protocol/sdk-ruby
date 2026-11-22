# frozen_string_literal: true

# Bank data: create a Bank Link, wait for the connection and read its accounts.
#
#   export DIDIT_API_KEY=...            # an API key with the bank-data permission
#   ruby -Ilib examples/bank_connection.rb
#
# The script prints the hosted Bank Link URL, waits for the person to finish and then
# reads the connection, its accounts and balances. In production, handle the
# bank.connection.created webhook instead of polling (examples/webhooks/).

require "didit"

FINAL_LINK_STATUSES = %w[completed cancelled expired failed].freeze

didit = Didit::Client.new

link = didit.bank.create_link(
  redirect_url: ENV.fetch("DIDIT_REDIRECT_URL", "https://acme.test/bank/return"),
  access: "ongoing",
  vendor_data: "customer-42"
)
puts "Bank Link #{link.id}: open #{link.url}"

# Wait for the person. The bank.connection.created webhook is the production path.
loop do
  link = didit.bank.get_link(link.id)
  break if FINAL_LINK_STATUSES.include?(link.status)

  sleep 2
end
abort "Bank Link #{link.status}" unless link.status == "completed"

connection = didit.bank.get_connection(link.connection_id)
puts "Connection #{connection.id}: #{connection.status}"

accounts = didit.bank.list_accounts(connection.id, limit: 50)
accounts.items.each do |account|
  puts "- #{account.name} (#{account.currency})"
  didit.bank.get_balances(account.id).balances.each do |balance|
    puts "  #{balance.amount} #{balance.currency}" # a decimal string, never a float
  end
end

account = accounts.items.first
abort "No accounts" unless account

didit.bank.list_transactions(account.id, limit: 50).items.each do |transaction|
  puts "#{transaction.booking_date} #{transaction.amount} #{transaction.currency} #{transaction.description}"
end
