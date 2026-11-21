# frozen_string_literal: true

RSpec.describe Didit::Page do
  include ApiHelpers

  let(:client) { generated_test_client }
  let(:base) { "https://verification.didit.me/v3/sessions/" }

  def page_json(ids, next_url, count: 5, previous: nil)
    JSON.generate(count: count, next: next_url, previous: previous, results: ids.map { |id| { session_id: id } })
  end

  def stub_pages(first_next, second_next: nil)
    stub_request(:get, base).with(query: { "limit" => "2" })
                            .to_return(body: page_json(%w[a b], first_next), headers: json_headers)
    stub_request(:get, base).with(query: { "limit" => "2", "offset" => "2" })
                            .to_return(body: page_json(%w[c d], second_next), headers: json_headers)
    stub_request(:get, base).with(query: { "limit" => "2", "offset" => "4" })
                            .to_return(body: page_json(%w[e], nil), headers: json_headers)
  end

  def json_headers
    { "Content-Type" => "application/json" }
  end

  it "exposes the page fields and iterates this page" do
    stub_pages("#{base}?limit=2&offset=2")
    page = client.sessions.list(limit: 2)
    expect(page.total_count).to eq(5)
    expect(page.next_url).to eq("#{base}?limit=2&offset=2")
    expect(page.previous_url).to be_nil
    expect(page.next_page?).to be(true)
    expect(page.map(&:session_id)).to eq(%w[a b])
    expect(page.count).to eq(2)
    expect(page.results.first).to be_a(Didit::Types::SessionsListResponseResults)
    expect(page[:count]).to eq(5)
    expect(page.to_h[:results].size).to eq(2)
    expect(page.each).to be_a(Enumerator)
    expect(page.inspect).to include("total_count=5")
  end

  it "auto-paginates across pages, following absolute and relative links" do
    stub_pages("#{base}?limit=2&offset=2", second_next: "/v3/sessions/?limit=2&offset=4")
    ids = []
    client.sessions.list(limit: 2).auto_paging_each { |s| ids << s.session_id }
    expect(ids).to eq(%w[a b c d e])
    expect(client.sessions.list(limit: 2).auto_paging_each.map(&:session_id)).to eq(%w[a b c d e])
  end

  it "sends the API key and request options to every page" do
    stub_pages("#{base}?limit=2&offset=2", second_next: "#{base}?limit=2&offset=4")
    client.sessions.list(limit: 2, request_options: { extra_headers: { "X-Trace" => "t" } }).auto_paging_each.to_a
    expect(a_request(:get, base).with(query: hash_including({}),
                                      headers: { "X-Trace" => "t",
                                                 "X-Api-Key" => "test-key" }))
      .to have_been_made.times(3)
  end

  it "returns nil for next_page on the last page" do
    stub_request(:get, base).to_return(body: page_json(%w[a], nil), headers: json_headers)
    page = client.sessions.list
    expect(page.next_page?).to be(false)
    expect(page.next_page).to be_nil
    expect(page.auto_paging_each.to_a.size).to eq(1)
  end

  it "refuses a next link on another origin before sending anything there" do
    ["https://evil.example/v3/sessions/?offset=2", "http://verification.didit.me/v3/sessions/?offset=2",
     "https://verification.didit.me:8443/v3/sessions/", "javascript:alert(1)"].each do |link|
      stub_request(:get, base).to_return(body: page_json(%w[a], link), headers: json_headers)
      page = client.sessions.list
      expect { page.next_page }.to raise_error(Didit::APIResponseValidationError, /another origin|invalid/)
    end
    expect(a_request(:get, /evil\.example/)).not_to have_been_made
  end

  it "stops with an error when the links loop" do
    stub_request(:get, base).with(query: { "limit" => "2" })
                            .to_return(body: page_json(%w[a], "#{base}?offset=2&limit=2"), headers: json_headers)
    stub_request(:get, base).with(query: { "limit" => "2", "offset" => "2" })
                            .to_return(body: page_json(%w[b], "#{base}?limit=2#again"), headers: json_headers)
    expect { client.sessions.list(limit: 2).auto_paging_each.to_a }
      .to raise_error(Didit::APIResponseValidationError, /twice/)
  end

  it "stops when a page links to itself" do
    stub_request(:get, base).to_return(body: page_json(%w[a], base), headers: json_headers)
    expect { client.sessions.list.next_page }.to raise_error(Didit::APIResponseValidationError, /twice/)
  end

  it "raises the status error of a failed next page" do
    stub_request(:get, base).with(query: { "limit" => "2" })
                            .to_return(body: page_json(%w[a], "#{base}?limit=2&offset=2"), headers: json_headers)
    stub_request(:get, base).with(query: { "limit" => "2", "offset" => "2" }).to_return(status: 404)
    expect { client.sessions.list(limit: 2).next_page }.to raise_error(Didit::NotFoundError)
  end

  it "is lenient with a page that has no results" do
    stub_request(:get, base).to_return(body: '{"count":0}', headers: json_headers)
    page = client.sessions.list
    expect(page.results).to eq([])
    expect(page.total_count).to eq(0)
  end

  it "works with with_raw_response" do
    stub_request(:get, base).to_return(body: page_json(%w[a], nil), headers: json_headers.merge("X-Request-Id" => "r1"))
    raw = client.with_raw_response.sessions.list
    expect(raw.request_id).to eq("r1")
    expect(raw.parse).to be_a(described_class)
    expect(raw.parse.map(&:session_id)).to eq(%w[a])
  end
end
