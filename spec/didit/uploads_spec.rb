# frozen_string_literal: true

require "pathname"
require "stringio"
require "tempfile"

RSpec.describe Didit::FilePart do
  include ApiHelpers

  let(:client) { generated_test_client }

  def sent_parts(calls)
    request = calls.requests.first
    parse_multipart(request.body, header(request, "Content-Type").split("boundary=", 2).last)
  end

  it "accepts a Pathname, an IO, a String of bytes or a FilePart" do
    Tempfile.create(["passport", ".png"]) do |file|
      file.binmode
      file.write("png-bytes")
      file.flush
      sources = {
        "path" => Pathname(file.path),
        "io" => File.open(file.path, "rb"),
        "string" => "raw-bytes",
        "stringio" => StringIO.new("io-bytes"),
        "part" => described_class.new("part-bytes", filename: "front.webp")
      }
      sources.each do |kind, source|
        calls = stub_api(body: "{}")
        client.id_verification.verify(front_image: source)
        part = sent_parts(calls)[:files]["front_image"]
        case kind
        when "path", "io" then expect(part).to eq([File.basename(file.path), "image/png", "png-bytes"])
        when "string" then expect(part).to eq(%w[front_image application/octet-stream raw-bytes])
        when "stringio" then expect(part).to eq(%w[front_image application/octet-stream io-bytes])
        when "part" then expect(part).to eq(%w[front.webp image/webp part-bytes])
        end
        WebMock.reset!
      end
      sources["io"].close
    end
  end

  it "sends the other fields as text: JSON for objects, true/false, numbers, nil left out" do
    calls = stub_api(body: "{}")
    client.document_ai.analyze(document: described_class.new("pdf", filename: "doc.pdf"),
                               fields: [{ name: "total", type: "number" }])
    parts = sent_parts(calls)
    expect(parts[:files]["document"]).to eq(%w[doc.pdf application/pdf pdf])
    expect(parts[:fields]["fields"]).to eq('[{"name":"total","type":"number"}]')
    calls = stub_api(body: "{}")
    client.face_match.compare(user_image: "a", ref_image: "b", rotate_image: true, face_match_score_decline_threshold: 40)
    expect(sent_parts(calls)[:fields]).to include("rotate_image" => "true", "face_match_score_decline_threshold" => "40")
  end

  it "uses JSON for operations that accept both when no file is given, and multipart when one is" do
    calls = stub_api(body: "{}")
    client.database_validation.validate(issuing_state: "ESP")
    expect(header(calls.requests.first, "Content-Type")).to eq("application/json")
    WebMock.reset!
    calls = stub_api(body: "{}")
    client.database_validation.validate(issuing_state: "ESP", selfie: "face")
    expect(header(calls.requests.first, "Content-Type")).to start_with("multipart/form-data; boundary=didit-")
    expect(sent_parts(calls)[:fields]).to eq({ "issuing_state" => "ESP" })
  end

  it "guesses content types from a fixed table" do
    { "a.JPG" => "image/jpeg", "b.heic" => "image/heic", "c.pdf" => "application/pdf", "d" => "application/octet-stream",
      "e.unknown" => "application/octet-stream" }.each do |name, type|
      expect(described_class.new("x", filename: name).content_type).to eq(type)
    end
    expect(described_class.new("x", filename: "a.png", content_type: "image/x-custom").content_type).to eq("image/x-custom")
  end

  it "escapes quotes and line breaks in names" do
    calls = stub_api(body: "{}")
    client.id_verification.verify(front_image: described_class.new("x", filename: "a\"b\r\nc.jpg"))
    expect(calls.requests.first.body).to include('filename="a%22b%0D%0Ac.jpg"')
  end

  it "rejects other values" do
    expect { described_class.new(42) }.to raise_error(Didit::ConfigurationError, /Pathname, an IO or a String/)
    expect { client.id_verification.verify(front_image: 42) }.to raise_error(Didit::ConfigurationError)
  end

  it "builds from a path and reads it" do
    Tempfile.create(["doc", ".pdf"]) do |file|
      File.binwrite(file.path, "%PDF")
      part = described_class.from_path(file.path)
      expect(part.filename).to eq(File.basename(file.path))
      expect(part.read).to eq("%PDF")
      expect(part.inspect).to include("application/pdf")
    end
  end

  it "re-sends the same bytes when a request is retried" do
    allow(Didit::Internal::Util).to receive(:pause)
    stub = stub_request(:post, %r{/v3/id-verification/}).to_return({ status: 429 }, { status: 200, body: "{}" })
    generated_test_client(max_retries: 1).id_verification.verify(front_image: StringIO.new("once"))
    expect(stub).to have_been_requested.twice
    expect(a_request(:post, %r{/v3/id-verification/}).with { |r| r.body.include?("once") }).to have_been_made.twice
  end
end
