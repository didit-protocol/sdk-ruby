# frozen_string_literal: true

require "json"
require "securerandom"

module Didit
  module Internal
    # multipart/form-data bodies. Files are read into memory, so a retry can send them again.
    # @api private
    module Multipart
      module_function

      # @return [Array(String, String)] the body and its content type
      def encode(fields, file_fields)
        boundary = "didit-#{SecureRandom.hex(16)}"
        body = +"".b
        fields.each do |name, value|
          next if value.nil?

          if file_fields.include?(name) || value.is_a?(FilePart)
            Array(value).each { |item| file_part(body, boundary, name, FilePart.wrap(item, name)) }
          else
            field_part(body, boundary, name, text(value))
          end
        end
        body << "--#{boundary}--\r\n"
        [body, "multipart/form-data; boundary=#{boundary}"]
      end

      def text(value)
        case value
        when Hash, Array then JSON.generate(Request.json_value(value))
        when Time then value.utc.iso8601(6)
        when Date then value.iso8601
        else value.to_s
        end
      end

      def field_part(body, boundary, name, value)
        body << "--#{boundary}\r\n"
        body << "Content-Disposition: form-data; name=\"#{quote(name)}\"\r\n\r\n"
        body << value.to_s.b << "\r\n"
      end

      def file_part(body, boundary, name, part)
        body << "--#{boundary}\r\n"
        body << "Content-Disposition: form-data; name=\"#{quote(name)}\"; filename=\"#{quote(part.filename)}\"\r\n"
        body << "Content-Type: #{part.content_type}\r\n\r\n"
        body << part.read << "\r\n"
      end

      # Escapes a name for a Content-Disposition parameter (WHATWG multipart rules).
      def quote(value)
        value.to_s.b.gsub("\r", "%0D").gsub("\n", "%0A").gsub('"', "%22")
      end
    end
  end
end
