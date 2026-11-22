# frozen_string_literal: true

module DiditCodegen
  # Name conversions (docs/DESIGN.md sections 4 and 5.1).
  module Naming
    WORD = /[A-Z]+(?=[A-Z][a-z0-9])|[A-Z]?[a-z0-9]+|[A-Z]+|[0-9]+/

    # Ruby keywords: valid as method names and keyword labels, not as local variables.
    KEYWORDS = %w[
      __ENCODING__ __LINE__ __FILE__ BEGIN END alias and begin break case class def defined? do else elsif end
      ensure false for if in module next nil not or redo rescue retry return self super then true undef unless
      until when while yield
    ].freeze

    module_function

    def words(text)
      text.to_s.gsub(/[^A-Za-z0-9]+/, " ").scan(WORD)
    end

    # +key_people_checks+ -> +KeyPeopleChecks+; +ID verification+ -> +IdVerification+.
    def pascal(text)
      out = words(text).map { |w| capitalize(w) }.join
      return "Value" if out.empty?

      out.match?(/\A[0-9]/) ? "V#{out}" : out
    end

    def capitalize(word)
      return word[0] + word[1..].downcase if word.length > 1 && word == word.upcase

      word[0].upcase + word[1..]
    end

    # +sessionId+ -> +session_id+; +Idempotency-Key+ -> +idempotency_key+.
    def snake(text)
      out = words(text).map(&:downcase).join("_")
      return "value" if out.empty?

      out.match?(/\A[0-9]/) ? "v_#{out}" : out
    end

    # +In Review+ -> +IN_REVIEW+; +status.updated+ -> +STATUS_UPDATED+.
    def constant(text)
      out = words(text).map(&:upcase).join("_")
      return "VALUE" if out.empty?

      out.match?(/\A[0-9]/) ? "V_#{out}" : out
    end

    # +sessions.imports+ -> +["Sessions", "Imports"]+.
    def resource_classes(resource)
      resource.split(".").map { |segment| pascal(segment) }
    end

    # A Ruby identifier for a JSON or parameter name, unique within +taken+.
    def identifier(name, taken = [])
      out = name.match?(/\A[a-z_][a-z0-9_]*\z/) ? name : snake(name)
      out = out.sub(/\A_+/, "")
      out = "value" if out.empty?
      out += "_" while taken.include?(out)
      out
    end

    def keyword?(name)
      KEYWORDS.include?(name)
    end
  end
end
