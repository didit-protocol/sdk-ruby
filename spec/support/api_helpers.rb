# frozen_string_literal: true

require "json"
require "uri"

# Helpers for the generated operation tests (spec/generated) and the core tests:
# a WebMock stub that records requests, and assertions on what was sent.
module ApiHelpers
  TEST_API_KEY = "test-key"
  TEST_ACCOUNT_TOKEN = "test-account-token"

  # Requests a stub received, the exact URLs the SDK sent (WebMock normalises its copy)
  # and the body it answered with.
  class Recorder
    attr_reader :requests, :urls, :body

    def initialize(body)
      @requests = []
      @urls = []
      @body = body
    end
  end

  def generated_test_client(**options)
    Didit::Client.new(api_key: TEST_API_KEY, account_token: TEST_ACCOUNT_TOKEN, organization_id: "org-7f3a",
                      application_id: "app-91c2", max_retries: 0, **options)
  end

  # Answers every request with +status+ and +body+, recording what was sent.
  def stub_api(status: 200, body: nil, content_type: "application/json", headers: {})
    recorder = Recorder.new(body)
    record_urls(recorder)
    response_headers = headers.dup
    response_headers["Content-Type"] = content_type if content_type
    stub_request(:any, /.*/).to_return do |request|
      recorder.requests << request
      { status: status, headers: response_headers, body: body.to_s }
    end
    recorder
  end

  # Records the URL of every request as the SDK built it.
  def record_urls(recorder)
    transport = Didit::Internal::Transport
    # rubocop:disable-next-line RSpec/AnyInstance
    allow_any_instance_of(transport).to receive(:execute).and_wrap_original do |original, *args, &block|
      recorder.urls << args[1].to_s
      original.call(*args, &block)
    end
  end

  # Asserts exactly one request was sent, with this method, URL (without query), query pairs in order,
  # and credentials.
  def expect_api_request(recorder, method:, url:, query: [], auth: :api_key, accept: "application/json")
    expect(recorder.requests.size).to eq(1)
    request = recorder.requests.first
    uri = URI(recorder.urls.first)
    expect(request.method).to eq(method)
    expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq(url)
    expect(uri.query ? URI.decode_www_form(uri.query) : []).to eq(query)
    expect_sdk_headers(request, auth, accept)
    request
  end

  def expect_sdk_headers(request, auth, accept)
    expect_credentials(request, auth)
    expect(header(request, "Accept")).to eq(accept)
    expect(header(request, "User-Agent")).to start_with("didit-ruby/#{Didit::VERSION} (")
    expect(header(request, "X-Didit-Client")).to eq("ruby/#{Didit::VERSION}")
  end

  def expect_credentials(request, auth)
    case auth
    when :api_key
      expect(header(request, "x-api-key")).to eq(TEST_API_KEY)
      expect(header(request, "Authorization")).to be_nil
    when :account_token
      expect(header(request, "Authorization")).to eq("Bearer #{TEST_ACCOUNT_TOKEN}")
      expect(header(request, "x-api-key")).to be_nil
    else
      expect(header(request, "Authorization")).to be_nil
      expect(header(request, "x-api-key")).to be_nil
    end
  end

  # A request header by case-insensitive name.
  def header(request, name)
    request.headers.find { |k, _| k.casecmp?(name) }&.last
  end

  def expect_json_body(request, expected)
    expect(header(request, "Content-Type")).to eq("application/json")
    expect(JSON.parse(request.body)).to eq(expected)
  end

  def expect_no_body(request)
    expect(request.body.to_s).to eq("")
  end

  # +fields+: name => text; +files+: name => [filename, content type, bytes].
  def expect_multipart_body(request, fields:, files:)
    content_type = header(request, "Content-Type")
    expect(content_type).to start_with("multipart/form-data; boundary=")
    parsed = parse_multipart(request.body, content_type.split("boundary=", 2).last)
    expect(parsed[:fields]).to eq(fields)
    expect(parsed[:files]).to eq(files)
  end

  def parse_multipart(body, boundary)
    out = { fields: {}, files: {} }
    body.b.split("--#{boundary}".b).each do |part|
      next if part.empty? || part.start_with?("--")

      head, data = part.delete_prefix("\r\n").split("\r\n\r\n".b, 2)
      data = data.delete_suffix("\r\n")
      name = head[/name="([^"]*)"/, 1]
      filename = head[/filename="([^"]*)"/, 1]
      if filename
        out[:files][name] = [filename, head[/Content-Type: (.*)/i, 1].strip, data]
      else
        out[:fields][name] = data.force_encoding(Encoding::UTF_8)
      end
    end
    out
  end

  # Calls every typed reader of a model (and of nested models), so a reader that raises fails the test.
  def exercise_readers(value, depth = 0)
    return if depth > 8

    case value
    when Didit::Model
      value.class.fields.each_key { |name| exercise_readers(value.public_send(name), depth + 1) }
    when Array
      value.first(3).each { |item| exercise_readers(item, depth + 1) }
    when Hash
      value.values.first(3).each { |item| exercise_readers(item, depth + 1) }
    end
  end
end
