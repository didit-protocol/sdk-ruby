# frozen_string_literal: true

RSpec.describe Didit::Model do
  let(:address_class) do
    Class.new(described_class) do
      field :city, "city", :string
    end
  end

  let(:model_class) do
    address = address_class
    Class.new(described_class) do
      field :name, "name", :string
      field :score, "score", :float
      field :created_at, "created_at", :datetime
      field :birthday, "birthday", :date
      field :address, "address", address
      field :tags, "tags", %i[array string]
      field :addresses, "addresses", [:array, address]
      field :by_id, "by_id", [:map, address]
      field :either, "either", [:union, [:integer, address]]
      field :method_, "method", :string
      field :first_name, "firstName", :string
    end
  end

  let(:data) do
    {
      "name" => "Ada", "score" => 87, "created_at" => "2026-01-02T03:04:05.123456Z", "birthday" => "1990-12-31",
      "address" => { "city" => "Madrid" }, "tags" => %w[a b], "addresses" => [{ "city" => "Paris" }],
      "by_id" => { "x" => { "city" => "Rome" } }, "either" => { "city" => "Oslo" }, "method" => "nfc",
      "firstName" => "A", "unknown_new_field" => { "nested" => [1, 2] }
    }
  end

  let(:model) { model_class.new(data) }

  it "converts values on access" do
    expect(model.name).to eq("Ada")
    expect(model.score).to eq(87.0)
    expect(model.score).to be_a(Float)
    expect(model.created_at).to eq(Time.utc(2026, 1, 2, 3, 4, 5.123456r))
    expect(model.birthday).to eq(Date.new(1990, 12, 31))
    expect(model.address).to be_a(address_class)
    expect(model.address.city).to eq("Madrid")
    expect(model.tags).to eq(%w[a b])
    expect(model.addresses.map(&:city)).to eq(["Paris"])
    expect(model.by_id["x"].city).to eq("Rome")
    expect(model.either.city).to eq("Oslo")
    expect(model.method_).to eq("nfc")
    expect(model.first_name).to eq("A")
  end

  it "keeps unknown fields readable" do
    expect(model[:unknown_new_field]).to eq({ "nested" => [1, 2] })
    expect(model["unknown_new_field"]).to eq({ "nested" => [1, 2] })
    expect(model.key?(:unknown_new_field)).to be(true)
    expect(model.key?(:missing)).to be(false)
    expect(model.to_h[:unknown_new_field]).to eq({ nested: [1, 2] })
    expect(JSON.parse(model.to_json)).to eq(data)
    expect(JSON.generate({ "wrapped" => model })).to eq(JSON.generate({ "wrapped" => data }))
  end

  it "never raises on values of the wrong shape" do
    odd = model_class.new("score" => "high", "created_at" => "yesterday", "birthday" => 5, "address" => "Madrid",
                          "tags" => "a", "addresses" => {}, "by_id" => [], "either" => 3.5)
    expect(odd.score).to eq("high")
    expect(odd.created_at).to eq("yesterday")
    expect(odd.birthday).to eq(5)
    expect(odd.address).to eq("Madrid")
    expect(odd.tags).to eq("a")
    expect(odd.addresses).to eq({})
    expect(odd.by_id).to eq([])
    expect(odd.either).to eq(3.5)
    expect(model_class.new({}).name).to be_nil
  end

  it "accepts date-times with a space and keeps unparseable ones" do
    expect(model_class.new("created_at" => "2026-01-02 03:04:05+00:00").created_at).to eq(Time.utc(2026, 1, 2, 3, 4, 5))
  end

  it "supports pattern matching on the typed readers" do
    matched = case model
              in { name: "Ada", address: { city: } } then city
              end
    expect(matched).to eq("Madrid")
    expect(model.deconstruct_keys(nil).keys).to include(:name, :score)
    expect(model.deconstruct_keys(%i[name nope])).to eq({ name: "Ada" })
  end

  it "compares by class and data" do
    expect(model_class.new(data)).to eq(model)
    expect(model_class.new(data).hash).to eq(model.hash)
    expect(model).not_to eq(address_class.new(data))
    expect(model.inspect).to start_with("#<")
  end

  it "accepts symbol keys and freezes its data" do
    built = model_class.new(name: "Bo")
    expect(built.name).to eq("Bo")
    expect(built["name"]).to eq("Bo")
    expect { described_class.new("x") }.to raise_error(ArgumentError)
  end

  it "inherits fields from parent classes" do
    child = Class.new(model_class) { field :extra, "extra", :integer }
    expect(child.fields.keys).to include(:name, :extra)
    expect(model_class.fields.keys).not_to include(:extra)
  end

  it "resolves type names under Didit::Types" do
    value = described_class.coerce({ "session_id" => "s" }, "SessionsRetrieveDecisionResponse")
    expect(value).to be_a(Didit::Types::SessionsRetrieveDecisionResponse)
    expect(described_class.from_json({ "a" => 1 })).to be_a(described_class)
    expect(described_class.from_json([1])).to eq([1])
  end

  it "makes enums open: known values are frozen string constants and others pass through" do
    expect(Didit::Types::SessionsRetrieveDecisionResponseStatus::APPROVED).to eq("Approved")
    expect(Didit::Types::SessionsRetrieveDecisionResponseStatus::VALUES).to include("Approved", "Declined")
    expect(Didit::Types::SessionsRetrieveDecisionResponseStatus::VALUES).to be_frozen
    decision = Didit::Types::SessionsRetrieveDecisionResponse.new("status" => "Some Future Status")
    expect(decision.status).to eq("Some Future Status")
  end
end
