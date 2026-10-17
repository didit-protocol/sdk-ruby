# frozen_string_literal: true

# Standalone AML screening: sanctions, PEP and adverse media for a person or a company.
#
#   export DIDIT_API_KEY=...
#   ruby -Ilib examples/aml_screening.rb "Maria Garcia" 1985-03-14 ESP

require "didit"

full_name, date_of_birth, nationality = ARGV
abort 'usage: ruby examples/aml_screening.rb "Full Name" [YYYY-MM-DD] [ISO3 country]' unless full_name

didit = Didit::Client.new
result = didit.aml.screen(
  full_name: full_name,
  date_of_birth: date_of_birth || Didit::OMIT,
  nationality: nationality || Didit::OMIT,
  vendor_data: "user-42"
)
aml = result.aml
puts "Status: #{aml&.status}, score #{aml&.score.inspect}, #{aml&.total_hits.to_i} hits"
Array(aml&.hits).first(5).each do |hit|
  puts "- #{hit.caption} (match #{hit.match_score.inspect}, datasets: #{Array(hit.datasets).join(', ')})"
end
