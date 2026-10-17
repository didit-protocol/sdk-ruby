# frozen_string_literal: true

module DiditCodegen
  # A type in the generated code. Kinds: :string, :integer, :float, :boolean, :datetime,
  # :date, :any, :object (free-form Hash), :model (a response class, by name), :record
  # (a request object, by RBS alias name), :array, :map, :union, :file (upload), :binary.
  class TypeRef
    attr_reader :kind, :name, :inner, :members, :nullable

    def initialize(kind, name: nil, inner: nil, members: nil, nullable: false)
      @kind = kind
      @name = name
      @inner = inner
      @members = members
      @nullable = nullable
    end

    def self.scalar(kind)
      new(kind)
    end

    def with_nullable(value = true)
      TypeRef.new(kind, name: name, inner: inner, members: members, nullable: nullable || value)
    end

    def ==(other)
      other.is_a?(TypeRef) && other.signature == signature
    end
    alias eql? ==

    def hash
      signature.hash
    end

    def signature
      [kind, name, inner&.signature, members&.map(&:signature), nullable]
    end

    # The type spec Didit::Model.coerce understands, as Ruby source.
    def runtime
      case kind
      when :model then name.inspect
      when :array then "[:array, #{inner.runtime}]"
      when :map then "[:map, #{inner.runtime}]"
      when :union then "[:union, [#{members.map(&:runtime).join(', ')}]]"
      when :string, :integer, :float, :boolean, :datetime, :date then ":#{kind}"
      else ":any"
      end
    end

    # The RBS type of a response value (nil allowed when +optional+).
    def rbs_response(optional: false)
      base = case kind
             when :string, :binary then "String"
             when :integer then "Integer"
             when :float then "Float"
             when :boolean then "bool"
             when :datetime then "Time"
             when :date then "Date"
             when :model then "Didit::Types::#{name}"
             when :array then "Array[#{inner.rbs_response}]"
             when :map then "Hash[String, #{inner.rbs_response}]"
             when :object then "Hash[String, untyped]"
             when :union then union_rbs(members.map(&:rbs_response))
             else "untyped"
             end
      optionalize(base, optional || nullable)
    end

    # The RBS type of a request argument (nil allowed when +optional+).
    def rbs_request(optional: false)
      base = case kind
             when :string then "String"
             when :integer then "Integer"
             when :float then "Float | Integer"
             when :boolean then "bool"
             when :datetime then "Time | String"
             when :date then "Date | String"
             when :record then "Didit::Types::#{name}"
             when :array then "Array[#{inner.rbs_request}]"
             when :map then "Hash[String | Symbol, #{inner.rbs_request}]"
             when :object then "Hash[String | Symbol, untyped]"
             when :union then union_rbs(members.map(&:rbs_request))
             when :file then "Didit::upload"
             else "untyped"
             end
      optionalize(base, optional || nullable)
    end

    private

    def union_rbs(parts)
      parts = parts.flat_map { |p| p.delete_prefix("(").delete_suffix(")").split(" | ") }.uniq
      return "untyped" if parts.include?("untyped")

      parts.size == 1 ? parts.first : "(#{parts.join(' | ')})"
    end

    def optionalize(base, optional)
      return base if !optional || base == "untyped" || base.end_with?("?")

      base.include?(" | ") && !base.start_with?("(") ? "(#{base})?" : "#{base}?"
    end
  end

  FieldDef = Struct.new(:reader, :wire, :type, :required, :description, :deprecated, keyword_init: true)

  # A response class (a Didit::Model subclass).
  ClassDef = Struct.new(:name, :group, :description, :fields, :superclass, keyword_init: true)
  # An open enum: a module of frozen string constants.
  EnumDef = Struct.new(:name, :group, :description, :values, keyword_init: true)
  # A request object: an RBS record type alias (the SDK sends Hashes).
  RecordDef = Struct.new(:name, :group, :description, :fields, keyword_init: true)

  # Every generated type, by name.
  class Registry
    attr_reader :classes, :enums, :records

    def initialize
      @classes = {}
      @enums = {}
      @records = {}
    end

    def taken?(name)
      @classes.key?(name) || @enums.key?(name)
    end

    def add_class(defn)
      raise Error, duplicate(defn.name) if taken?(defn.name)

      @classes[defn.name] = defn
    end

    def add_enum(defn)
      existing = @enums[defn.name]
      return existing if existing && existing.values == defn.values
      raise Error, duplicate(defn.name) if taken?(defn.name)

      @enums[defn.name] = defn
    end

    def add_record(defn)
      raise Error, duplicate(defn.name) if @records.key?(defn.name)

      @records[defn.name] = defn
    end

    def groups
      (@classes.values + @enums.values + @records.values).map(&:group).uniq.sort
    end

    private

    def duplicate(name)
      "Two different types are both named #{name}; rename one of the operations or properties in " \
        "openapi/overlay.json."
    end
  end

  # OpenAPI schemas to Ruby types (docs/DESIGN.md section 5.1). Response objects become
  # Didit::Model subclasses; request objects become RBS record types; string enums become
  # modules of frozen string constants. $ref components keep their component name; inline
  # objects take their parent's name plus the property name.
  class TypeBuilder
    # Readers a model cannot define without hiding Object or Didit::Model methods.
    MODEL_METHODS = %w[
      ! != !~ <=> == === =~ __id__ __send__ class clone define_singleton_method display dup enum_for eql? equal?
      extend freeze frozen? hash inspect instance_eval instance_exec instance_of? instance_variable_defined?
      instance_variable_get instance_variable_set instance_variables is_a? itself kind_of? method methods nil?
      object_id private_methods protected_methods public_method public_methods public_send
      remove_instance_variable respond_to? send singleton_class singleton_method singleton_methods
      tap then to_enum to_s yield_self
      [] key? to_h to_json deconstruct_keys deconstruct raw_data read_field initialize
    ].freeze

    attr_reader :registry

    def initialize(documents)
      @documents = documents
      @registry = Registry.new
      @component_models = {}
      @component_records = {}
      @pointer_models = {}
      @pointer_records = {}
      @component_names = component_names
    end

    def component_name(document, name)
      @component_names.fetch([document.name, name])
    end

    # The type of a response value. +hint+ names inline objects; +group+ is the file they go to.
    def response(document, schema, hint, group)
      ref = response_inner(document, schema, hint, group)
      schema.is_a?(Hash) && schema["nullable"] == true ? ref.with_nullable : ref
    end

    # The type of a request value.
    def request(document, schema, hint, group)
      ref = request_inner(document, schema, hint, group)
      schema.is_a?(Hash) && schema["nullable"] == true ? ref.with_nullable : ref
    end

    # Merges allOf parts into one property map: [properties, required names].
    def collect(document, schema)
      props = {}
      required = Array(schema["required"])
      (schema["allOf"] || []).each do |part|
        sub_props, sub_required = collect(document, document.resolve(part))
        props.merge!(sub_props)
        required |= sub_required
      end
      props.merge!(schema["properties"] || {})
      [props, required]
    end

    private

    def component_names
      by_doc = @documents.transform_values { |d| d.components.keys }
      out = {}
      @documents.each_value do |document|
        others = by_doc.reject { |name, _| name == document.name }.values.flatten
        document.components.each_key do |name|
          ruby = name.match?(/\A[A-Z][A-Za-z0-9]*\z/) ? name : Naming.pascal(name)
          ruby = "Account#{ruby}" if document.name == "account" && others.include?(name)
          out[[document.name, name]] = ruby
        end
      end
      out
    end

    def component_group(document)
      document.name.start_with?("account") ? "account_components" : "components"
    end

    # Responses --------------------------------------------------------------

    def response_inner(document, schema, hint, group)
      return TypeRef.scalar(:any) unless schema.is_a?(Hash)

      if (ref = schema["$ref"])
        return component_response(document, ref.split("/").last) if ref.start_with?("#/components/schemas/")

        return pointer_response(document, ref, hint, group)
      end
      if schema.key?("allOf")
        parts = schema["allOf"]
        return response(document, parts.first, hint, group) if parts.size == 1 && !schema["properties"]

        return model(document, schema, hint, group)
      end
      %w[oneOf anyOf].each do |key|
        return union_response(document, schema, schema[key], hint, group) if schema.key?(key)
      end
      return enum(schema, hint, group) if schema.key?("enum")

      basic_response(document, schema, hint, group)
    end

    def basic_response(document, schema, hint, group)
      case schema["type"]
      when "string" then string_type(schema, :binary)
      when "integer" then TypeRef.scalar(:integer)
      when "number" then TypeRef.scalar(:float)
      when "boolean" then TypeRef.scalar(:boolean)
      when "array" then TypeRef.new(:array, inner: response(document, schema["items"] || {}, hint, group))
      else
        return TypeRef.scalar(:any) unless schema["type"] == "object" || schema.key?("properties")
        return model(document, schema, hint, group) unless (schema["properties"] || {}).empty?

        extra = schema["additionalProperties"]
        return TypeRef.scalar(:object) unless extra.is_a?(Hash) && !extra.empty?

        TypeRef.new(:map, inner: response(document, extra, "#{hint}Value", group))
      end
    end

    def string_type(schema, binary_kind)
      case schema["format"]
      when "date-time" then TypeRef.scalar(:datetime)
      when "date" then TypeRef.scalar(:date)
      when "binary" then TypeRef.scalar(binary_kind)
      else TypeRef.scalar(:string)
      end
    end

    def component_response(document, name)
      key = [document.name, name]
      schema = document.components.fetch(name) { raise Error, "#{document.name}: unknown component #{name}." }
      unless @component_models.key?(key)
        ruby = component_name(document, name)
        @component_models[key] = :pending
        ref = response_inner(document, schema, ruby, component_group(document))
        @component_models[key] = ref
      end
      ref = @component_models[key]
      ref = TypeRef.new(:model, name: component_name(document, name)) if ref == :pending
      schema["nullable"] == true ? ref.with_nullable : ref
    end

    # A $ref into #/paths/...: an inline schema used in several places, named after its first use.
    def pointer_response(document, ref, hint, group)
      key = [document.name, ref]
      @pointer_models[key] ||= response_inner(document, document.pointer(ref), hint, group)
    end

    def union_response(document, schema, members, hint, group)
      resolved = members.map { |m| document.resolve(m) }
      non_null = resolved.reject { |m| m["type"] == "null" }
      nullable = non_null.size < resolved.size
      ref = if non_null.all? { |m| object_schema?(m) }
              merged_model(document, schema, non_null, hint, group)
            else
              variants = members.each_with_index.filter_map do |m, i|
                next if document.resolve(m)["type"] == "null"

                response(document, m, "#{hint}#{variant_suffix(document, m, i)}", group)
              end
              TypeRef.new(:union, members: variants)
            end
      nullable ? ref.with_nullable : ref
    end

    # Requests ---------------------------------------------------------------

    def request_inner(document, schema, hint, group)
      return TypeRef.scalar(:any) unless schema.is_a?(Hash)

      if (ref = schema["$ref"])
        return component_request(document, ref.split("/").last) if ref.start_with?("#/components/schemas/")

        key = [document.name, ref]
        return @pointer_records[key] ||= request_inner(document, document.pointer(ref), hint, group)
      end
      if schema.key?("allOf")
        parts = schema["allOf"]
        return request(document, parts.first, hint, group) if parts.size == 1 && !schema["properties"]

        return record(document, schema, hint, group)
      end
      %w[oneOf anyOf].each do |key|
        next unless schema.key?(key)

        variants = schema[key].each_with_index.filter_map do |m, i|
          next if document.resolve(m)["type"] == "null"

          request(document, m, "#{hint}#{variant_suffix(document, m, i)}", group)
        end
        nullable = schema[key].any? { |m| document.resolve(m)["type"] == "null" }
        ref = variants.size == 1 ? variants.first : TypeRef.new(:union, members: variants)
        return nullable ? ref.with_nullable : ref
      end
      return enum(schema, hint, group) if schema.key?("enum")

      basic_request(document, schema, hint, group)
    end

    def basic_request(document, schema, hint, group)
      case schema["type"]
      when "string" then string_type(schema, :file)
      when "integer" then TypeRef.scalar(:integer)
      when "number" then TypeRef.scalar(:float)
      when "boolean" then TypeRef.scalar(:boolean)
      when "array" then TypeRef.new(:array, inner: request(document, schema["items"] || {}, hint, group))
      else
        return TypeRef.scalar(:any) unless schema["type"] == "object" || schema.key?("properties")
        return record(document, schema, hint, group) unless (schema["properties"] || {}).empty?

        extra = schema["additionalProperties"]
        return TypeRef.scalar(:object) unless extra.is_a?(Hash) && !extra.empty?

        TypeRef.new(:map, inner: request(document, extra, "#{hint}Value", group))
      end
    end

    def component_request(document, name)
      key = [document.name, name]
      schema = document.components.fetch(name) { raise Error, "#{document.name}: unknown component #{name}." }
      unless @component_records.key?(key)
        ruby = component_name(document, name)
        @component_records[key] = :pending
        ref = request_inner(document, schema, ruby, component_group(document))
        @component_records[key] = ref
      end
      ref = @component_records[key]
      ref = TypeRef.new(:record, name: record_alias(component_name(document, name))) if ref == :pending
      schema["nullable"] == true ? ref.with_nullable : ref
    end

    # Shared -----------------------------------------------------------------

    def object_schema?(schema)
      schema.is_a?(Hash) && (schema["type"] == "object" || schema.key?("properties") || schema.key?("allOf")) &&
        !schema.key?("enum")
    end

    def variant_suffix(document, member, index)
      title = document.resolve(member)["title"] if member.is_a?(Hash)
      title.is_a?(String) && !title.strip.empty? ? Naming.pascal(title) : "Variant#{index + 1}"
    end

    def enum(schema, hint, group)
      values = schema["enum"].compact
      if !values.empty? && values.all?(String)
        @registry.add_enum(EnumDef.new(name: hint, group: group, description: description(schema),
                                       values: values.uniq))
        return TypeRef.scalar(:string)
      end
      return TypeRef.scalar(:integer) if schema["type"] == "integer" || (!values.empty? && values.all?(Integer))
      return TypeRef.scalar(:boolean) if schema["type"] == "boolean"
      return TypeRef.scalar(:float) if schema["type"] == "number"

      TypeRef.scalar(:any)
    end

    def model(document, schema, name, group)
      props, required = collect(document, schema)
      superclass, props = inherited(document, schema, props, required)
      define_model(document, schema, name, group, props, required, superclass)
    end

    # allOf with exactly one object component and own properties: a subclass of that component.
    def inherited(document, schema, props, required)
      refs = (schema["allOf"] || []).select { |p| p.is_a?(Hash) && p["$ref"].to_s.start_with?("#/components/schemas/") }
      return [nil, props] unless refs.size == 1

      target = document.resolve(refs.first)
      return [nil, props] unless target["properties"] && !target.key?("allOf") && target.fetch("type", "object") == "object"

      base = component_response(document, refs.first["$ref"].split("/").last)
      return [nil, props] unless base.kind == :model

      base_required = Array(target["required"])
      own = props.reject do |k, _|
        target["properties"].key?(k) && required.include?(k) == base_required.include?(k)
      end
      [base.name, own]
    end

    def merged_model(document, schema, members, hint, group)
      props = {}
      required_sets = []
      members.each do |member|
        member_props, member_required = collect(document, member)
        member_props.each { |k, v| props[k] ||= v }
        required_sets << member_required
      end
      required = required_sets.reduce { |a, b| a & b } || []
      define_model(document, schema, hint, group, props, required, nil)
    end

    def define_model(document, schema, name, group, props, required, superclass)
      defn = ClassDef.new(name: name, group: group, description: description(schema), fields: [],
                          superclass: superclass)
      # Registered first, so nested names can never collide with it.
      @registry.add_class(defn)
      taken = MODEL_METHODS.dup
      props.each do |wire, prop|
        resolved = document.resolve(prop)
        next if prop.is_a?(Hash) && (prop["writeOnly"] == true || resolved["writeOnly"] == true)

        type = response(document, prop, "#{name}#{Naming.pascal(wire)}", group)
        reader = Naming.identifier(wire, taken)
        taken << reader
        defn.fields << FieldDef.new(reader: reader, wire: wire, type: type, required: required.include?(wire),
                                    description: description(prop) || description(resolved),
                                    deprecated: resolved["deprecated"] == true)
      end
      TypeRef.new(:model, name: name)
    end

    def record(document, schema, hint, group)
      props, required = collect(document, schema)
      alias_name = record_alias(hint)
      defn = RecordDef.new(name: alias_name, group: group, description: description(schema), fields: [])
      @registry.add_record(defn)
      props.each do |wire, prop|
        resolved = document.resolve(prop)
        next if resolved["readOnly"] == true

        type = request(document, prop, "#{hint}#{Naming.pascal(wire)}", group)
        defn.fields << FieldDef.new(reader: wire, wire: wire, type: type, required: required.include?(wire),
                                    description: description(prop) || description(resolved),
                                    deprecated: resolved["deprecated"] == true)
      end
      TypeRef.new(:record, name: alias_name)
    end

    # The RBS alias name of a request object: +SessionsCreateParams+ -> +sessions_create_params+.
    def record_alias(name)
      Naming.snake(name)
    end

    def description(schema)
      text = schema.is_a?(Hash) ? schema["description"] : nil
      text.is_a?(String) && !text.strip.empty? ? text.strip : nil
    end
  end
end
