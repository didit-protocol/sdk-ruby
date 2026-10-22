# frozen_string_literal: true

module DiditCodegen
  # Writes the RBS signatures of the generated layer: sig/didit/types* and sig/didit/resources*.
  class RbsRenderer
    RBS_KEYWORDS = %w[
      alias attr_accessor attr_reader attr_writer bool bot class def end extend false include instance interface
      module nil out prepend private public self singleton super top true type unchecked untyped void use as
    ].freeze

    def initialize(registry, methods, resource_tree)
      @registry = registry
      @methods = methods
      @tree = resource_tree
    end

    # @return [Hash{String => String}] relative path => content
    def files
      out = {}
      @registry.groups.each { |group| out["sig/didit/types/#{group}.rbs"] = types_file(group) }
      out["sig/didit/resources.rbs"] = resources_index
      @tree.children.each_value { |node| out["sig/didit/resources/#{node.segment}.rbs"] = resource_file(node) }
      out
    end

    def self.method_name(name)
      Naming.keyword?(name) || RBS_KEYWORDS.include?(name) ? "`#{name}`" : name
    end

    private

    def types_file(group)
      in_group = ->(defs) { defs.values.select { |d| d.group == group }.sort_by(&:name) }
      blocks = in_group.call(@registry.enums).map { |e| enum_block(e) } +
               in_group.call(@registry.classes).map { |c| class_block(c) } +
               in_group.call(@registry.records).map { |r| record_block(r) }
      <<~RBS
        #{HEADER}

        module Didit
          module Types
        #{blocks.join("\n").rstrip}
          end
        end
      RBS
    end

    def enum_block(enum)
      used = ["VALUES"]
      lines = ["    module #{enum.name}"]
      enum.choices.each do |value|
        name = Naming.constant(value)
        name += "_" while used.include?(name)
        used << name
        lines << "      #{name}: String"
      end
      lines << ""
      lines << "      VALUES: Array[String]"
      lines << "    end"
      "#{lines.join("\n")}\n"
    end

    def class_block(defn)
      superclass = defn.superclass ? "Didit::Types::#{defn.superclass}" : "Didit::Model"
      lines = ["    class #{defn.name} < #{superclass}"]
      defn.fields.each do |field|
        optional = !field.required
        type = field.type.rbs_response(optional: optional)
        lines << "      def #{RbsRenderer.method_name(field.reader)}: () -> #{type}"
      end
      lines << "    end"
      "#{lines.join("\n")}\n"
    end

    def record_block(record)
      fields = record.fields.map do |field|
        "#{"?" unless field.required}#{field.wire}: #{field.type.rbs_request}"
      end
      body = fields.empty? ? "{ }" : "{ #{fields.join(", ")} }"
      "    type #{record.name} = #{body}\n"
    end

    def resources_index
      accessors = @tree.children.each_value.map do |node|
        "      def #{RbsRenderer.method_name(node.segment)}: () -> Didit::Resources::#{node.path_name}"
      end
      <<~RBS
        #{HEADER}

        module Didit
          module Resources
            module ClientMethods
        #{accessors.join("\n")}
            end
          end
        end
      RBS
    end

    def resource_file(node)
      <<~RBS
        #{HEADER}

        module Didit
          module Resources
        #{resource_class(node, "    ").rstrip}
          end
        end
      RBS
    end

    def resource_class(node, indent)
      lines = ["#{indent}class #{node.class_name} < Didit::Resource"]
      lines << "#{indent}  include ::Didit::Webhooks::ClientMethods" if node.resource == "webhooks"
      node.children.each_value do |child|
        lines << "#{indent}  def #{RbsRenderer.method_name(child.segment)}: () -> Didit::Resources::#{child.path_name}"
      end
      node.methods.sort_by(&:name).each { |m| lines.concat(method_sig(m, "#{indent}  ")) }
      node.children.each_value { |child| lines << resource_class(child, "#{indent}  ").rstrip }
      lines << "#{indent}end"
      "#{lines.join("\n")}\n"
    end

    def method_sig(meth, indent)
      params = meth.path_args.map { |a| "String #{a.name}" }
      if meth.whole_body
        params << "#{"?" unless meth.whole_body.required}#{meth.whole_body.name}: #{meth.whole_body.type.rbs_request}"
      end
      meth.kwargs.each do |a|
        params << "#{"?" unless a.required}#{a.name}: #{a.type.rbs_request}"
      end
      params << "?#{meth.idempotency.name}: String" if meth.idempotency
      params << "?request_options: Didit::request_options?"
      name = RbsRenderer.method_name(meth.name)
      head = "#{indent}def #{name}: (#{params.join(", ")})"
      resp = meth.response
      case resp.kind
      when :none then ["#{head} -> nil"]
      when :binary
        pad = " " * (indent.length + name.length + 4)
        ["#{head} -> String", "#{pad}| (#{params.join(", ")}) { (String chunk) -> void } -> nil"]
      when :page then ["#{head} -> Didit::Page[#{resp.item.rbs_response}]"]
      else ["#{head} -> #{resp.type.rbs_response(optional: resp.optional)}"]
      end
    end
  end
end
