# frozen_string_literal: true

# Wallet screening and the Travel Rule: screen a counterparty wallet, find its VASP and
# open a widget session for the wallet's owner to prove ownership.
#
#   export DIDIT_API_KEY=...
#   ruby -Ilib examples/travel_rule.rb <wallet address> [chain]

require "didit"

wallet, chain = ARGV
abort "usage: ruby examples/travel_rule.rb <wallet address> [chain]" unless wallet
chain ||= "ethereum"

didit = Didit::Client.new
screening = didit.wallet_screening.screen(wallet_address: wallet, blockchain: chain)
puts "Wallet risk: #{screening.risk_level.inspect} (score #{screening.risk_score.inspect})"

vasps = didit.travel_rule.list_vasps(search: "exchange", limit: 5)
puts "VASPs (#{vasps.total_count}): #{vasps.map(&:name).join(', ')}"

widget = didit.travel_rule.create_widget_session(wallet_address: wallet, chain: chain, vendor_data: "user-42")
puts "Ownership widget: #{widget[:url] || widget.to_h.inspect}"

# A screening report as a PDF, streamed to a file.
File.open("wallet-screening.pdf", "wb") do |file|
  didit.wallet_screening.screen_pdf(wallet_address: wallet, blockchain: chain) { |chunk| file.write(chunk) }
end
puts "Saved wallet-screening.pdf"
