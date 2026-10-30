# frozen_string_literal: true

require "pathname"

module Didit
  # A file to upload (docs/DESIGN.md section 8), with an optional file name and content type.
  #
  # Upload arguments accept a +Pathname+ (read from disk), an +IO+ such as +File+ or
  # +StringIO+ (read once), a +String+ holding the file's bytes, or a FilePart:
  #
  #   didit.id_verification.verify(front_image: Pathname("passport.jpg"))
  #   didit.id_verification.verify(front_image: File.open("passport.jpg", "rb"))
  #   didit.id_verification.verify(front_image: Didit::FilePart.new(bytes, filename: "front.png"))
  class FilePart
    # File types by extension. A fixed table, so uploads do not depend on the host's MIME database.
    CONTENT_TYPES = {
      ".bmp" => "image/bmp", ".csv" => "text/csv", ".gif" => "image/gif", ".heic" => "image/heic",
      ".heif" => "image/heif", ".jpeg" => "image/jpeg", ".jpg" => "image/jpeg", ".json" => "application/json",
      ".mov" => "video/quicktime", ".mp4" => "video/mp4", ".pdf" => "application/pdf", ".png" => "image/png",
      ".tif" => "image/tiff", ".tiff" => "image/tiff", ".txt" => "text/plain", ".webm" => "video/webm",
      ".webp" => "image/webp", ".zip" => "application/zip"
    }.freeze
    DEFAULT_CONTENT_TYPE = "application/octet-stream"

    # @return [String, Pathname, IO]
    attr_reader :content
    # @return [String, nil]
    attr_reader :filename

    # @param content [String, Pathname, IO] the bytes, a path to read, or an IO to read
    # @param filename [String, nil] defaults to the path's base name
    # @param content_type [String, nil] defaults to a type guessed from the file name
    def initialize(content, filename: nil, content_type: nil)
      unless content.is_a?(String) || content.is_a?(Pathname) || content.respond_to?(:read)
        raise ConfigurationError, "A file must be a Pathname, an IO or a String of bytes, got #{content.class}."
      end

      @content = content
      @filename = filename || FilePart.default_filename(content)
      @content_type = content_type
    end

    # A FilePart for a path on disk.
    def self.from_path(path, filename: nil, content_type: nil)
      new(Pathname(path), filename: filename, content_type: content_type)
    end

    # Wraps an upload argument; +field+ names the file when nothing else does.
    # @api private
    def self.wrap(value, field)
      part = value.is_a?(FilePart) ? value : new(value)
      part.filename ? part : new(part.content, filename: field, content_type: part.content_type)
    end

    # @api private
    def self.default_filename(content)
      path = if content.is_a?(Pathname)
               content
             elsif content.respond_to?(:path) && content.path
               content.path
             end
      path ? File.basename(path.to_s) : nil
    end

    # @return [String]
    def content_type
      @content_type || CONTENT_TYPES.fetch(File.extname(filename.to_s).downcase, DEFAULT_CONTENT_TYPE)
    end

    # The file's bytes (an IO is read once, from its current position).
    # @return [String]
    def read
      data = case content
             when Pathname then File.binread(content.to_s)
             when String then content
             else content.read
             end
      data.to_s.b
    end

    def inspect
      "#<Didit::FilePart filename=#{filename.inspect} content_type=#{content_type.inspect}>"
    end
  end
end
