# frozen_string_literal: true

# Standalone ID verification: check a document image without a session.
#
#   export DIDIT_API_KEY=...
#   ruby -Ilib examples/id_verification.rb front.jpg [back.jpg]

require "didit"
require "pathname"

front, back = ARGV
abort "usage: ruby examples/id_verification.rb front.jpg [back.jpg]" unless front

didit = Didit::Client.new
result = didit.id_verification.verify(
  front_image: Pathname(front),
  back_image: back ? Pathname(back) : Didit::OMIT,
  vendor_data: "user-42"
)
verification = result.id_verification
puts "Status: #{verification&.status}"
puts "Name: #{verification&.first_name} #{verification&.last_name}"
puts "Document: #{verification&.document_type} #{verification&.document_number}"
puts "Warnings: #{Array(verification&.warnings).map { |w| w[:risk] }.join(', ')}"
