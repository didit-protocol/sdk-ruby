# frozen_string_literal: true

require "date"
require "json"
require "time"

module Didit
  # Base class of every response type.
  #
  # A model wraps the JSON object the API returned. Typed readers convert values
  # on access (nested objects become models, date-times become +Time+) and never
  # raise: a value that does not have the documented shape is returned as is.
  # Fields the SDK does not know yet stay readable with {#[]} and {#to_h}.
  #
  # Field types are written as +:string+, +:integer+, +:float+, +:boolean+,
  # +:datetime+, +:date+, +:any+, a model class (or its name under +Didit::Types+),
  # +[:array, type]+, +[:map, type]+ or +[:union, [type, ...]]+ (the first type that fits the value).
  class Model
    class << self
      # The typed fields of this class and its ancestors: reader name => [JSON name, type].
      #
      # @return [Hash{Symbol => Array}]
      def fields
        @fields ||= superclass <= Model ? superclass.fields.dup : {}
      end

      # Declares a typed reader +name+ for the JSON property +wire+.
      #
      # @return [void]
      def field(name, wire, type = :any)
        fields[name] = [wire, type].freeze
        define_method(name) { read_field(name) }
      end

      # Builds an instance from a parsed JSON value; anything but an object is returned unchanged.
      def from_json(value)
        value.is_a?(Hash) ? new(value) : value
      end

      # Converts a parsed JSON +value+ to +type+, leniently.
      def coerce(value, type)
        return value if value.nil?

        case type
        when Array then coerce_container(value, type)
        when :float then value.is_a?(Integer) ? value.to_f : value
        when :datetime then parse_time(value)
        when :date then parse_date(value)
        when Symbol then value
        else coerce_model(value, type)
        end
      end

      private

      def coerce_container(value, type)
        kind, inner = type
        if kind == :union
          member = inner.find { |m| fits?(value, m) }
          member ? coerce(value, member) : value
        elsif kind == :array && value.is_a?(Array)
          value.map { |item| coerce(item, inner) }
        elsif kind == :map && value.is_a?(Hash)
          value.transform_values { |item| coerce(item, inner) }
        else
          value
        end
      end

      # Whether +value+ has the JSON shape of +type+ (for unions).
      def fits?(value, type)
        case value
        when Hash then type.is_a?(String) || type.is_a?(Class) || (type.is_a?(Array) && type.first == :map)
        when Array then type.is_a?(Array) && type.first == :array
        when String then %i[string datetime date].include?(type)
        when Integer then %i[integer float].include?(type)
        when Float then type == :float
        when true, false then type == :boolean
        else false
        end
      end

      def coerce_model(value, type)
        klass = type.is_a?(String) ? Didit::Types.const_get(type, false) : type
        value.is_a?(Hash) && klass.is_a?(Class) && klass <= Model ? klass.new(value) : value
      end

      def parse_time(value)
        return value unless value.is_a?(String)

        Time.iso8601(value.sub(" ", "T"))
      rescue ArgumentError
        value
      end

      def parse_date(value)
        return value unless value.is_a?(String)

        Date.iso8601(value)
      rescue ArgumentError
        value
      end
    end

    # @param data [Hash] the JSON object, as parsed (string keys); symbol keys are accepted too
    def initialize(data = {})
      raise ArgumentError, "#{self.class.name} needs a Hash, got #{data.class}" unless data.is_a?(Hash)

      @data = (data.each_key.all?(String) ? data : data.transform_keys(&:to_s)).freeze
      @cache = {}
    end

    # The raw JSON value of any property, known to the SDK or not.
    #
    # @param key [String, Symbol] the property name as the API sends it
    def [](key)
      @data[key.to_s]
    end

    # Whether the API sent the property (also when its value is +null+).
    def key?(key)
      @data.key?(key.to_s)
    end

    # The JSON object as a Hash with symbol keys, nested objects included.
    #
    # @return [Hash{Symbol => Object}]
    def to_h
      Model.symbolize(@data)
    end

    # @return [String] the JSON object, unchanged
    def to_json(*args)
      @data.to_json(*args)
    end

    # Pattern matching on the typed readers: +in {status: "Approved"}+.
    def deconstruct_keys(keys)
      names = keys || self.class.fields.keys
      names.each_with_object({}) do |name, out|
        out[name] = public_send(name) if self.class.fields.key?(name)
      end
    end

    def ==(other)
      other.class == self.class && other.raw_data == @data
    end
    alias eql? ==

    def hash
      [self.class, @data].hash
    end

    def inspect
      "#<#{self.class.name} #{@data.inspect}>"
    end
    alias to_s inspect

    # @api private
    def self.symbolize(value)
      case value
      when Hash then value.to_h { |k, v| [k.to_sym, symbolize(v)] }
      when Array then value.map { |v| symbolize(v) }
      else value
      end
    end

    protected

    # @api private
    def raw_data
      @data
    end

    private

    def read_field(name)
      return @cache[name] if @cache.key?(name)

      wire, type = self.class.fields.fetch(name)
      @cache[name] = Model.coerce(@data[wire], type)
    end
  end
end
