# frozen_string_literal: true

require "json"

module DiditCodegen
  module Sync
    # JSON files written back in the layout they already have, and SDK naming helpers.
    module JsonText
      module_function

      # +data+ as JSON laid out like +original+: its indentation, its trailing newline and,
      # when it escapes non-ASCII characters, the same escaping. One space and no trailing
      # newline (the layout of the seeded openapi/ files) when there is no original.
      def dump_like(original, data)
        template = original.to_s
        indent = template[/\n([ \t]+)\S/, 1] || " "
        ascii = template.include?("\\u") && template.ascii_only?
        text = JSON.generate(data, indent: indent, space: " ", object_nl: "\n", array_nl: "\n", ascii_only: ascii)
        template.end_with?("\n") ? "#{text}\n" : text
      end

      # x-didit-sdk with sorted keys and no empty scope, for comparisons and display.
      def normalize(naming)
        return naming unless naming.is_a?(Hash)

        naming.reject { |k, v| k == "scope" && v.nil? }.sort.to_h
      end

      def compact(naming)
        JSON.generate(normalize(naming))
      end

      # "sessions.imports.create" for a server operation's naming, else nil.
      def ident(naming)
        return nil unless naming.is_a?(Hash) && naming["server"] == true
        return nil unless naming["resource"].is_a?(String) && naming["method"].is_a?(String)

        "#{naming["resource"]}.#{naming["method"]}"
      end

      # "sessions.imports.create" for any naming (server or not), else nil.
      def name_of(naming)
        return nil unless naming.is_a?(Hash) && naming["resource"].is_a?(String) && naming["method"].is_a?(String)

        "#{naming["resource"]}.#{naming["method"]}"
      end
    end
  end
end
