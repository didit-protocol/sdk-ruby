# frozen_string_literal: true

# Regenerates the SDK's generated layer from openapi/ (docs/DESIGN.md section 5).
#
#   ruby codegen/generate.rb          # write the generated files
#   ruby codegen/generate.rb --check  # exit 1 when the committed files are stale

require_relative "lib/didit_codegen"

root = File.expand_path("..", __dir__)
check = ARGV.include?("--check")
unknown = ARGV - ["--check"]
abort "usage: ruby codegen/generate.rb [--check]" unless unknown.empty?

begin
  generator = DiditCodegen::Generator.new(root)
  if check
    result = generator.check
    problems = result.values.sum(&:size)
    if problems.zero?
      puts "Generated code is up to date (#{generator.files.size} files)."
    else
      warn "Generated code is stale. Run `bundle exec rake generate` and commit the result:"
      result[:missing].each { |path| warn "  missing: #{path}" }
      result[:changed].each { |path| warn "  changed: #{path}" }
      result[:stale].each { |path| warn "  not generated any more (delete it): #{path}" }
      exit 1
    end
  else
    changed = generator.write
    puts "Generated #{generator.files.size} files (#{changed.size} changed)."
  end
rescue DiditCodegen::Error => e
  warn "codegen: #{e.message}"
  exit 2
end
