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

    # Public methods every Ruby 3.1 object has, the supported floor. The list is fixed so generated
    # names do not vary by the Ruby version that runs the generator. An operation with one of these
    # names gets the resource singular appended instead; see #operation_method.
    OBJECT_RESERVED = %w[
      ! != !~ <=> == === =~ __id__ __send__ class clone define_singleton_method display dup enum_for eql? equal?
      extend freeze frozen? hash inspect instance_eval instance_exec instance_of? instance_variable_defined?
      instance_variable_get instance_variable_set instance_variables is_a? itself kind_of? method methods nil?
      object_id private_methods protected_methods public_method public_methods public_send remove_instance_variable
      respond_to? send singleton_class singleton_method singleton_methods taint tainted? tap then to_enum to_s trust
      untaint untrust untrusted? yield_self
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

    # +messages+ -> +message+; +categories+ -> +category+.
    def singular(text)
      word = text.to_s
      return word unless word.end_with?("s")
      return word if word.end_with?("ss", "us", "is")
      return "#{word[0..-4]}y" if word.end_with?("ies") && word.length > 3

      word[0..-2]
    end

    # The Ruby method name of an operation: a name every Ruby object already has keeps its meaning
    # and gets the singular resource appended (+messages.send+ becomes +messages.send_message+).
    def operation_method(resource, method)
      return method unless OBJECT_RESERVED.include?(method)

      "#{method}_#{singular(resource.split(".").last)}"
    end
  end
end
