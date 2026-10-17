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
puts "Wallet risk: #{screening.severity} (score #{screening.risk_score.inspect}): #{screening.summary}"

vasps = didit.travel_rule.list_vasps(search: "exchange", limit: 5)
puts "VASPs (#{vasps.total_count}): #{vasps.map(&:name).join(', ')}"

widget = didit.travel_rule.create_widget_session(wallet_address: wallet, chain: chain, vendor_data: "user-42")
puts "Ownership widget: #{widget.url} (expires #{widget.expires_at})"

# The screening as a signed PDF report: send the result back, stream the PDF to a file.
pdf_fields = didit.wallet_screening.method(:screen_pdf).parameters.map(&:last)
File.open("wallet-screening.pdf", "wb") do |file|
  didit.wallet_screening.screen_pdf(**screening.to_h.slice(*pdf_fields)) { |chunk| file.write(chunk) }
end
puts "Saved wallet-screening.pdf"
