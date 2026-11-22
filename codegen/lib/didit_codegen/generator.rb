# frozen_string_literal: true

require "fileutils"

module DiditCodegen
  # A node of the resource tree: +sessions+, +sessions.imports+, ...
  class ResourceNode
    attr_reader :segment, :resource, :parent, :children, :methods

    def initialize(segment, resource, parent)
      @segment = segment
      @resource = resource
      @parent = parent
      @children = {}
      @methods = []
    end

    def class_name
      Naming.pascal(segment)
    end

    # +Sessions::Imports+
    def path_name
      chain = []
      node = self
      while node&.parent
        chain.unshift(node.class_name)
        node = node.parent
      end
      chain.join("::")
    end

    def child(segment)
      @children[segment] ||= ResourceNode.new(segment, [resource, segment].compact.join("."), self)
    end
  end

  # Builds the generated layer from openapi/ and writes or checks it.
  class Generator
    # Directories (and files) the generator owns; anything else in them is an error.
    OUTPUTS = {
      "lib/didit/types" => ".rb", "lib/didit/resources" => ".rb", "sig/didit/types" => ".rbs",
      "sig/didit/resources" => ".rbs", "spec/generated" => "_spec.rb"
    }.freeze
    OUTPUT_FILES = %w[lib/didit/types.rb lib/didit/resources.rb sig/didit/resources.rbs].freeze

    # Methods of Didit::Client a top-level resource accessor may not replace.
    CLIENT_RESERVED = %w[
      request request_page with_options with_raw_response deprecated close api_key account_token organization_id
      application_id base_url account_base_url timeout max_retries default_headers logger raw_response? inspect
      config transport
    ].freeze
    # Methods of Didit::Resource an operation may not replace.
    RESOURCE_RESERVED = (TypeBuilder::MODEL_METHODS + %w[client]).freeze

    attr_reader :spec, :types, :methods, :tree

    def initialize(root)
      @root = root
      @spec = Spec.load(File.join(root, "openapi"))
      @types = TypeBuilder.new(@spec.documents)
      builder = OperationBuilder.new(@types)
      operations = @spec.server_operations.sort_by { |op| [op.sdk.resource, op.sdk.method] }
      @methods = operations.map { |op| builder.build(op) }
      @tree = build_tree
      check_names
    end

    # @return [Hash{String => String}] every generated file, relative path => content
    def files
      out = {}
      out.merge!(RubyRenderer.new(@types.registry, @methods, @tree).files)
      out.merge!(RbsRenderer.new(@types.registry, @methods, @tree).files)
      out.merge!(SpecRenderer.new(@types, @tree).files)
      out.sort.to_h
    end

    # Writes the files and deletes generated files that are no longer produced.
    # @return [Array<String>] the paths that changed
    def write
      wanted = files
      changed = []
      wanted.each do |path, content|
        full = File.join(@root, path)
        next if File.exist?(full) && File.read(full, encoding: "UTF-8") == content

        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, content, mode: "wb")
        changed << path
      end
      stale(wanted).each do |path|
        File.delete(File.join(@root, path))
        changed << path
      end
      changed
    end

    # @return [Hash{Symbol => Array<String>}] :missing, :changed and :stale paths
    def check
      wanted = files
      missing = []
      changed = []
      wanted.each do |path, content|
        full = File.join(@root, path)
        if !File.exist?(full)
          missing << path
        elsif File.read(full, encoding: "UTF-8") != content
          changed << path
        end
      end
      { missing: missing, changed: changed, stale: stale(wanted) }
    end

    private

    def build_tree
      root = ResourceNode.new(nil, nil, nil)
      @methods.each do |meth|
        node = meth.resource.split(".").reduce(root) { |n, segment| n.child(segment) }
        node.methods << meth
      end
      sort_tree(root)
      root
    end

    def sort_tree(node)
      node.children.replace(node.children.sort.to_h)
      node.children.each_value { |child| sort_tree(child) }
    end

    def check_names
      @tree.children.each_key do |segment|
        next unless CLIENT_RESERVED.include?(segment)

        raise Error, "The top-level resource #{segment.inspect} would replace Didit::Client##{segment}; rename it " \
                     "in openapi/overlay.json."
      end
      @methods.each do |meth|
        next unless RESOURCE_RESERVED.include?(meth.name)

        raise Error, "#{meth.op.key}: the method name #{meth.name.inspect} would replace a built-in Ruby method; " \
                     "rename it in openapi/overlay.json."
      end
    end

    def stale(wanted)
      existing = OUTPUTS.flat_map do |dir, suffix|
        Dir.glob(File.join(@root, dir, "**", "*#{suffix}")).map { |f| f.delete_prefix("#{@root}/") }
      end
      existing += OUTPUT_FILES.select { |f| File.exist?(File.join(@root, f)) }
      stale = existing.uniq.reject { |path| wanted.key?(path) }
      stale.each do |path|
        next if File.read(File.join(@root, path), encoding: "UTF-8").start_with?(HEADER)

        raise Error, "#{path} is in a generated directory but was not generated; move hand-written code elsewhere."
      end
      stale
    end
  end
end
