# frozen_string_literal: true

require "digest"
require "json"
require_relative "../didit_codegen"

module DiditCodegen
  # The spec sync (docs/DESIGN.md section 3.1): takes freshly downloaded upstream documents,
  # updates openapi/ (the upstream copies, SOURCE.json, overlay.json and
  # deprecated-operations.json), regenerates the SDK and describes what changed.
  module Sync
    UPSTREAM = {
      "verification.json" => "https://docs.didit.me/openapi-25.json",
      "account.json" => "https://docs.didit.me/openapi-auth.json"
    }.freeze
    # Names accepted by --from-dir besides the openapi/ ones: the upstream file names.
    UPSTREAM_NAMES = { "verification.json" => "openapi-25.json", "account.json" => "openapi-auth.json" }.freeze
    PREFIXES = { "verification.json" => "", "account.json" => "account " }.freeze
    SCHEMA_REF = "#/components/schemas/"
    DEPRECATED_FILE = "deprecated-operations.json"
    DEPRECATED_DESCRIPTION =
      "SDK methods kept for one minor version after their operation was removed or renamed upstream " \
      "(docs/DESIGN.md section 3.1). Written by codegen/spec_sync.rb; do not edit by hand. Each entry holds a " \
      "dereferenced copy of the operation as it was, the SDK naming it had, deprecated_since (the SDK version " \
      "when it was deprecated) and remove_in (the method ships deprecated through that version and is deleted " \
      "by the first sync after it)."
    VERSION_FILE = "lib/didit/version.rb"

    # A download or a local file the sync cannot work with; nothing is written.
    class InputError < StandardError; end

    # +generator_error+ is the DiditCodegen::Error the regeneration raised, if any.
    Result = Struct.new(:changed, :report, :generator_error, keyword_init: true)

    module_function

    # Parses +bytes+ and refuses anything that is not an OpenAPI 3 document with paths
    # (an error page or a maintenance JSON must never replace the contract).
    def check_document(label, bytes)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise InputError, "#{label}: the download is not UTF-8 text." unless text.valid_encoding?

      begin
        doc = JSON.parse(text)
      rescue JSON::ParserError => e
        raise InputError, "#{label}: the download is not JSON (#{e.message[0, 120]})."
      end
      raise InputError, "#{label}: the download is not a JSON object." unless doc.is_a?(Hash)

      version = doc["openapi"]
      unless version.is_a?(String) && version.start_with?("3.")
        raise InputError, "#{label}: the download is not an OpenAPI 3 document (openapi: #{version.inspect})."
      end

      paths = doc["paths"]
      raise InputError, "#{label}: the download has no paths." unless paths.is_a?(Hash) && !paths.empty?

      doc
    end

    # The SDK version in lib/didit/version.rb.
    def read_version(root)
      text = File.read(File.join(root, VERSION_FILE), encoding: "UTF-8")
      version = text[/VERSION\s*=\s*["'](\d+\.\d+\.\d+[^"']*)["']/, 1]
      raise InputError, "#{VERSION_FILE}: no VERSION = \"x.y.z\" found." unless version

      version
    rescue Errno::ENOENT
      raise InputError, "#{VERSION_FILE} is missing."
    end

    # The version through which a method deprecated in +version+ is kept: the next minor.
    def next_minor(version)
      major, minor = version.split(".").map(&:to_i)
      "#{major}.#{minor + 1}.0"
    end

    # True when +remove_in+ is a version and +current+ has reached it.
    def expired?(remove_in, current)
      Gem::Version.correct?(remove_in.to_s) && Gem::Version.new(remove_in.to_s) <= Gem::Version.new(current)
    end

    def sha256(bytes)
      bytes.nil? ? "none" : Digest::SHA256.hexdigest(bytes)
    end

    # Applies +downloads+ (file name in openapi/ => bytes) to the repository at +root+.
    def run(root, downloads, date:, now:)
      Syncer.new(root, downloads, date: date, now: now).run
    end
  end
end

require_relative "sync/document"
require_relative "sync/diff"
require_relative "sync/freeze"
require_relative "sync/json_text"
require_relative "sync/report"
require_relative "sync/download"
require_relative "sync/state"
require_relative "sync/methods"
require_relative "sync/changes"
require_relative "sync/syncer"
require_relative "sync/cli"
