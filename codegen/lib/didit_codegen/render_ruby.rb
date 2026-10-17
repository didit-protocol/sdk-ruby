# frozen_string_literal: true

module DiditCodegen
  # Comment text helpers shared by the renderers.
  module Text
    WIDTH = 118

    module_function

    # Comment lines for +text+ at +indent+, wrapped at 118 columns, without em or en dashes
    # (upstream descriptions use them).
    def comment(text, indent)
      return [] if text.nil? || text.strip.empty?

      fenced = false
      text.tr("—", "-").tr("–", "-").strip.lines.flat_map do |line|
        line = line.rstrip
        fenced = !fenced if line.lstrip.start_with?("```")
        next ["#{indent}#"] if line.empty?
        next ["#{indent}# #{line}"] if fenced || line.lstrip.start_with?("|", "```")

        wrap(line, WIDTH - indent.length - 2).map { |part| "#{indent}# #{part}" }
      end
    end

    # Splits +line+ at spaces so each part fits +width+; list items keep a hanging indent.
    def wrap(line, width)
      return [line] if line.length <= width

      hang = " " * (line[/\A\s*(?:[-*]|\d+\.)\s+/] || line[/\A\s*/]).length
      parts = []
      current = +""
      line.split(" ").each do |word|
        prefix = parts.empty? ? line[/\A\s*/] : hang
        candidate = current.empty? ? "#{prefix}#{word}" : "#{current} #{word}"
        if candidate.length > width && !current.empty?
          parts << current
          current = "#{hang}#{word}"
        else
          current = candidate
        end
      end
      parts << current unless current.empty?
      parts
    end

    def ruby_string(value)
      value.inspect
    end
  end

  # Writes the Ruby side of the generated layer: lib/didit/types* and lib/didit/resources*.
  class RubyRenderer
    def initialize(registry, methods, resource_tree)
      @registry = registry
      @methods = methods
      @tree = resource_tree
    end

    # @return [Hash{String => String}] relative path => content
    def files
      out = {}
      out["lib/didit/types.rb"] = types_index
      @registry.groups.each { |group| out["lib/didit/types/#{group}.rb"] = types_file(group) }
      out["lib/didit/resources.rb"] = resources_index
      @tree.children.each_value { |node| out["lib/didit/resources/#{node.segment}.rb"] = resource_file(node) }
      out
    end

    private

    def header
      "#{HEADER}\n# frozen_string_literal: true\n"
    end

    # Types -----------------------------------------------------------------

    def types_index
      entries = (@registry.classes.values + @registry.enums.values).sort_by(&:name).map do |defn|
        "    autoload :#{defn.name}, \"didit/types/#{defn.group}\""
      end
      <<~RUBY
        #{header}
        module Didit
          # The request and response types of the Didit API (docs/DESIGN.md section 5.1).
          # Each constant loads on first use.
          module Types
        #{entries.join("\n")}
          end
        end
      RUBY
    end

    def types_file(group)
      enums = @registry.enums.values.select { |e| e.group == group }.sort_by(&:name)
      classes = ordered_classes(group)
      blocks = enums.map { |e| enum_block(e) } + classes.map { |c| class_block(c) }
      body = blocks.join("\n")
      <<~RUBY
        #{header}
        module Didit
          module Types
        #{body.rstrip}
          end
        end
      RUBY
    end

    # Classes sorted by name, with a superclass from the same file before its subclasses.
    def ordered_classes(group)
      classes = @registry.classes.values.select { |c| c.group == group }.sort_by(&:name)
      done = []
      until classes.empty?
        ready = classes.find do |c|
          c.superclass.nil? || done.any? do |d|
            d.name == c.superclass
          end || @registry.classes[c.superclass].group != group
        end
        done << ready
        classes.delete(ready)
      end
      done
    end

    def enum_block(enum)
      lines = Text.comment(enum.description, "    ")
      lines << "    # Known values of an open enum: the API may send others." if lines.empty?
      lines << "    module #{enum.name}"
      used = ["VALUES"]
      names = enum.values.map do |value|
        name = Naming.constant(value)
        name += "_" while used.include?(name)
        used << name
        lines << "      #{name} = #{Text.ruby_string(value)}"
        name
      end
      lines << ""
      lines << "      VALUES = [#{names.join(", ")}].freeze"
      lines << "    end"
      "#{lines.join("\n")}\n"
    end

    def class_block(defn)
      lines = Text.comment(defn.description, "    ")
      superclass = defn.superclass || "Didit::Model"
      lines << "    class #{defn.name} < #{superclass}"
      defn.fields.each do |field|
        lines << "      field :#{field.reader}, #{Text.ruby_string(field.wire)}, #{field.type.runtime}"
      end
      lines << "    end"
      "#{lines.join("\n")}\n"
    end

    # Resources -------------------------------------------------------------

    def resources_index
      autoloads = @tree.children.each_value.map do |node|
        "    autoload :#{node.class_name}, \"didit/resources/#{node.segment}\""
      end
      accessors = @tree.children.each_value.map { |node| accessor(node, "      ") }
      <<~RUBY
        #{header}
        module Didit
          # One class per API resource, one method per operation (docs/DESIGN.md section 4).
          module Resources
        #{autoloads.join("\n")}

            # The top-level resources of Didit::Client.
            module ClientMethods
        #{accessors.join("\n\n")}
            end
          end
        end
      RUBY
    end

    def accessor(node, indent)
      [
        "#{indent}# @return [Didit::Resources::#{node.path_name}]",
        "#{indent}def #{node.segment}",
        "#{indent}  @#{node.segment} ||= Resources::#{node.path_name}.new(#{node.parent&.parent ? "@client" : "self"})",
        "#{indent}end"
      ].join("\n")
    end

    def resource_file(node)
      <<~RUBY
        #{header}
        module Didit
          module Resources
        #{resource_class(node, "    ").rstrip}
          end
        end
      RUBY
    end

    def resource_class(node, indent)
      lines = ["#{indent}# The +#{node.resource}+ resource."]
      lines << "#{indent}class #{node.class_name} < Didit::Resource"
      members = []
      members << "#{indent}  include ::Didit::Webhooks::ClientMethods" if node.resource == "webhooks"
      node.children.each_value { |child| members << nested_accessor(child, "#{indent}  ") }
      node.methods.sort_by(&:name).each { |m| members << method_source(m, "#{indent}  ") }
      node.children.each_value { |child| members << resource_class(child, "#{indent}  ").rstrip }
      lines << members.join("\n\n")
      lines << "#{indent}end"
      "#{lines.join("\n")}\n"
    end

    def nested_accessor(child, indent)
      [
        "#{indent}# @return [Didit::Resources::#{child.path_name}]",
        "#{indent}def #{child.segment}",
        "#{indent}  @#{child.segment} ||= #{child.class_name}.new(@client)",
        "#{indent}end"
      ].join("\n")
    end

    def method_source(meth, indent)
      lines = method_doc(meth, indent)
      lines.concat(signature(meth, indent))
      if meth.deprecated?
        lines << "#{indent}  @client.deprecated(#{"#{meth.resource}.#{meth.name}".inspect}, #{deprecation(meth).inspect})"
      end
      lines.concat(call_lines(meth, "#{indent}  "))
      lines << "#{indent}end"
      lines.join("\n")
    end

    # The def line, one parameter per line when it would pass 120 columns.
    def signature(meth, indent)
      params = parameters(meth)
      line = "#{indent}def #{meth.name}(#{params.join(", ")})"
      return [line] if line.length <= 120

      ["#{indent}def #{meth.name}(", *params.each_with_index.map do |p, i|
        "#{indent}  #{p}#{"," unless i == params.size - 1}"
      end, "#{indent})"]
    end

    def deprecation(meth)
      meth.op.deprecation_note || "The API marks this operation as deprecated."
    end

    def parameters(meth)
      params = meth.path_args.map(&:name)
      params << "#{meth.whole_body.name}:#{" OMIT" unless meth.whole_body.required}" if meth.whole_body
      meth.kwargs.each { |a| params << (a.required ? "#{a.name}:" : "#{a.name}: OMIT") }
      params << "#{meth.idempotency.name}: OMIT" if meth.idempotency
      params << "request_options: nil"
      params << "&block" if meth.response.kind == :binary
      params
    end

    def call_lines(meth, indent)
      op = meth.op
      args = [":#{op.http_method}", op.path.inspect]
      opts = []
      unless meth.path_args.empty?
        opts << "path_params: { #{meth.path_args.map { |a| "#{a.wire.inspect} => #{a.reader}" }.join(", ")} }"
      end
      opts << hash_option("query", meth.query_args, indent) unless meth.query_args.empty?
      if meth.whole_body
        opts << "body: #{meth.whole_body.reader}"
      elsif !meth.body_args.empty?
        opts << hash_option("body", meth.body_args, indent)
      elsif op.op["requestBody"]
        opts << "body: {}"
      end
      if %i[multipart auto].include?(meth.encoding)
        opts << "encoding: :#{meth.encoding}"
        opts << "file_fields: %w[#{meth.file_fields.join(" ")}]" unless meth.file_fields.empty?
      end
      opts << "headers: { #{meth.idempotency.wire.inspect} => #{meth.idempotency.reader} }" if meth.idempotency
      opts << "auth: :#{op.sdk.auth}" unless op.sdk.auth == "api_key"
      opts << "api: :account" if op.api == "account"
      opts << "scope: :application" if op.sdk.scope == "application"
      opts.concat(response_options(meth))
      opts << "request_options: request_options"
      all = args + opts
      lines = ["#{indent}@client.request("]
      all.each_with_index do |part, i|
        sep = i == all.size - 1 ? "" : ","
        lines << "#{indent}  #{part}#{sep}"
      end
      lines[-1] = "#{lines[-1]}, &block" if meth.response.kind == :binary
      lines << "#{indent})"
      lines
    end

    def hash_option(name, args, indent)
      entries = args.map { |a| "#{indent}    #{a.wire.inspect} => #{a.reader}" }
      "#{name}: {\n#{entries.join(",\n")}\n#{indent}  }"
    end

    def response_options(meth)
      resp = meth.response
      case resp.kind
      when :none then []
      when :binary then ["response: :binary", "accept: #{resp.accept.inspect}"]
      when :page then ["page: #{const(resp.item)}"]
      else
        if resp.by_status
          ["response: { #{resp.by_status.map { |code, type| "#{code} => #{const(type)}" }.join(", ")} }"]
        else
          ["response: #{const(resp.type)}"]
        end
      end
    end

    # A runtime type spec with model classes as constants.
    def const(type)
      case type.kind
      when :model then "Types::#{type.name}"
      when :array then "[:array, #{const(type.inner)}]"
      when :map then "[:map, #{const(type.inner)}]"
      when :union then "[:union, [#{type.members.map { |m| const(m) }.join(", ")}]]"
      else type.runtime
      end
    end

    def method_doc(meth, indent)
      lines = []
      lines.concat(Text.comment(meth.summary, indent))
      if meth.description && meth.description != meth.summary
        lines << "#{indent}#" unless lines.empty?
        lines.concat(Text.comment(meth.description, indent))
      end
      lines << "#{indent}#" unless lines.empty?
      lines << "#{indent}# +#{meth.op.http_method.upcase} #{meth.op.path}+"
      lines << "#{indent}#"
      meth.path_args.each { |a| lines.concat(param_doc(a, indent)) }
      lines.concat(param_doc(meth.whole_body, indent)) if meth.whole_body
      meth.kwargs.each { |a| lines.concat(param_doc(a, indent)) }
      if meth.idempotency
        lines << "#{indent}# @param #{meth.idempotency.name} [String] sent as the Idempotency-Key header"
      end
      lines << "#{indent}# @param request_options [Hash, nil] :timeout, :max_retries, :extra_headers, :extra_query, :extra_body"
      lines << return_doc(meth, indent)
      lines << "#{indent}# @deprecated #{deprecation(meth)}" if meth.deprecated?
      lines
    end

    def param_doc(arg, indent)
      text = arg.description ? " #{arg.description.gsub(/\s+/, " ").tr("—", "-").tr("–", "-")}" : ""
      text = "#{text[0, 400].rstrip}..." if text.length > 400
      first, *rest = Text.wrap("@param #{arg.name} [#{yard(arg.type, request: true)}]#{text}",
                               Text::WIDTH - indent.length - 2)
      ["#{indent}# #{first}", *rest.map { |part| "#{indent}#   #{part.strip}" }]
    end

    def return_doc(meth, indent)
      resp = meth.response
      case resp.kind
      when :none then "#{indent}# @return [nil]"
      when :binary then "#{indent}# @return [String, nil] the body bytes, or nil when a block receives the chunks"
      when :page then "#{indent}# @return [Didit::Page<#{yard(resp.item)}>]"
      else "#{indent}# @return [#{yard(resp.type)}#{", nil" if resp.optional}]"
      end
    end

    def yard(type, request: false)
      base = case type.kind
             when :string, :binary then "String"
             when :integer then "Integer"
             when :float then request ? "Numeric" : "Float"
             when :boolean then "Boolean"
             when :datetime then request ? "Time, String" : "Time"
             when :date then request ? "Date, String" : "Date"
             when :model then "Didit::Types::#{type.name}"
             when :record, :object then "Hash"
             when :array then "Array<#{yard(type.inner, request: request)}>"
             when :map then "Hash{String => #{yard(type.inner, request: request)}}"
             when :union then type.members.map { |m| yard(m, request: request) }.uniq.join(", ")
             when :file then "Pathname, IO, String, Didit::FilePart"
             else "Object"
             end
      type.nullable ? "#{base}, nil" : base
    end
  end
end
