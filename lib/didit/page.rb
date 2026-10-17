# frozen_string_literal: true

require "uri"

module Didit
  # One page of a list (docs/DESIGN.md section 8): the API's +{count, next, previous, results}+.
  #
  #   page = didit.sessions.list(limit: 50)
  #   page.each { |session| ... }               # this page
  #   page.auto_paging_each { |session| ... }   # every page, fetched as needed
  #
  # +total_count+ is the API's +count+ (Enumerable#count counts the items of this page).
  class Page
    include Enumerable

    # @return [Array] the items of this page, typed
    attr_reader :results

    # @api private
    def initialize(client:, prepared:, item:, data:, seen: nil)
      @client = client
      @prepared = prepared
      @item = item
      @data = data.is_a?(Hash) ? data : {}
      list = @data["results"]
      @results = list.is_a?(Array) ? list.map { |value| Model.coerce(value, item) } : []
      @seen = seen || [Page.normalize(prepared.uri)]
    end

    # @return [Integer, nil] the total number of items across pages
    def total_count
      @data["count"]
    end

    # @return [String, nil]
    def next_url
      link(@data["next"])
    end

    # @return [String, nil]
    def previous_url
      link(@data["previous"])
    end

    # Iterates the items of this page.
    def each(&)
      return enum_for(:each) unless block_given?

      results.each(&)
      self
    end

    def next_page?
      !next_url.nil?
    end

    # Fetches the next page, or returns nil on the last one.
    # @return [Didit::Page, nil]
    def next_page
      url = next_url
      return nil if url.nil?

      target = resolve(url)
      key = Page.normalize(target)
      if @seen.include?(key)
        raise APIResponseValidationError.new(
          "The API returned the pagination link #{Internal::Util.display_url(target)} twice; stopping to avoid " \
          "a loop.", status: 200
        )
      end
      @client.fetch_page(@prepared, target, @item, @seen + [key])
    end

    # Iterates every item of every page, fetching pages as needed.
    # @return [Enumerator] without a block
    def auto_paging_each(&block)
      return enum_for(:auto_paging_each) unless block

      # @type var page: Page[untyped]?
      page = self
      while page
        page.results.each(&block)
        page = page.next_page
      end
      nil
    end

    # The raw value of any property of the page.
    def [](key)
      @data[key.to_s]
    end

    # @return [Hash{Symbol => Object}]
    def to_h
      Model.symbolize(@data)
    end

    def inspect
      "#<Didit::Page total_count=#{total_count.inspect} results=#{results.size} next=#{next_page?}>"
    end

    # @api private
    def self.normalize(uri)
      uri = uri.dup
      uri.fragment = nil
      # @type var query: Array[[String, String]]
      query = uri.query ? URI.decode_www_form(uri.query).sort : []
      [Internal::Util.origin(uri), uri.path, query]
    end

    private

    def link(value)
      value.is_a?(String) && !value.strip.empty? ? value.strip : nil
    end

    def resolve(url)
      target = URI.join(@prepared.uri.to_s, url)
      unless %w[http https].include?(target.scheme) && Internal::Util.origin(target) == @prepared.origin
        raise APIResponseValidationError.new(
          "Refusing to follow a pagination link to another origin (#{Internal::Util.origin(target)}); " \
          "the API key is only sent to #{@prepared.origin}.", status: 200
        )
      end
      target
    rescue URI::Error => e
      raise APIResponseValidationError.new("The API returned an invalid pagination link: #{e.message}", status: 200)
    end
  end
end
