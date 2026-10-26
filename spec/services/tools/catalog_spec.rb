# frozen_string_literal: true

# Phase 4d — Catalog integrity. The marketplace may only advertise what this
# install can actually execute: every declared tool needs a real, callable
# executor class; every parameter schema must be a valid JSON Schema that
# accepts a generated sample; and org availability must follow connected +
# active ToolIntegration rows strictly (paused rows and tool-less providers
# surface nothing).
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/DescribedClass

require "rails_helper"
require "json_schemer"

RSpec.describe Tools::Catalog, type: :service do
  let(:organization) { create(:organization) }

  def sample_for(type)
    case type.to_s
    when "integer" then 1
    when "number" then 1.5
    when "boolean" then true
    when "array" then [ "sample" ]
    when "object" then {}
    else "sample"
    end
  end

  def sample_args(schema)
    schema.fetch(:properties, {}).transform_values { |prop| sample_for(prop[:type]) }
  end

  describe "structural integrity" do
    it "uses unique plugin keys drawn from ToolIntegration providers" do
      keys = Tools::Catalog.keys
      expect(keys.uniq.length).to eq(keys.length)
      expect(keys - ToolIntegration::PROVIDERS).to be_empty
    end

    it "describes every plugin with the fields the marketplace renders" do
      Tools::Catalog.all.each do |plugin|
        expect(plugin[:key]).to be_present
        expect(plugin[:name]).to be_present
        expect(plugin[:description]).to be_present
        expect(plugin[:category]).to be_present
        expect(plugin[:docs_url]).to be_present
        expect(plugin[:tools]).to be_an(Array)
        expect(plugin[:capabilities]).to be_an(Array)
      end
    end

    it "backs every declared tool with a real callable executor class" do
      pairs = Tools::Catalog.all.flat_map { |plugin| plugin[:tools].map { |tool| [ plugin[:key], tool ] } }
      expect(pairs).not_to be_empty
      pairs.each do |key, tool|
        executor = tool[:executor].safe_constantize
        expect(executor).not_to be_nil, "executor #{tool[:executor]} for #{key}.#{tool[:name]} does not resolve"
        expect(executor).to respond_to(:call), "#{tool[:executor]} is not callable"
      end
    end

    it "validates every tool parameter schema and a generated sample against it" do
      Tools::Catalog.all.each do |plugin|
        plugin[:tools].each do |tool|
          schemer = JSONSchemer.schema(tool[:parameters])
          expect(schemer.valid_schema?).to be(true), "#{plugin[:key]}.#{tool[:name]} has an invalid schema"
          errors = schemer.validate(sample_args(tool[:parameters])).map { |err| err["error"] }
          expect(errors).to be_empty, "sample args rejected for #{plugin[:key]}.#{tool[:name]}: #{errors}"
        end
      end
    end

    it "declares required properties that exist in the schema" do
      Tools::Catalog.all.each do |plugin|
        plugin[:tools].each do |tool|
          properties = tool[:parameters][:properties]
          Array(tool[:parameters][:required]).each do |req|
            expect(properties.keys.map(&:to_s)).to include(req.to_s), "#{plugin[:key]}.#{tool[:name]} requires unknown #{req}"
          end
        end
      end
    end

    it "namespaces tool names so they cannot collide with registry tools" do
      namespaced = Tools::Catalog.all_tool_names
      expect(namespaced.uniq.length).to eq(namespaced.length)
      namespaced.each do |name|
        plugin_key, tool_name = name.split(".", 2)
        expect(Tools::Catalog.find(plugin_key)).not_to be_nil
        expect(Tools::Catalog.tool(plugin_key, tool_name)).not_to be_nil
        expect(Agents::ToolRegistry.get(name)).to be_nil
      end
    end

    it "gives credential and config fields usable form metadata" do
      Tools::Catalog.all.each do |plugin|
        (plugin[:credential_fields] + plugin.fetch(:config_fields, [])).each do |field|
          expect(field[:key]).to be_present
          expect(field[:label]).to be_present
          expect(field[:type]).to be_in([ "password", "text" ])
          expect(field[:required]).to be_in([ true, false ])
        end
      end
    end

    it "ships google tool-less on purpose (no fake gmail executor)" do
      expect(Tools::Catalog.find("google")[:tools]).to be_empty
      expect(Tools::Catalog.tool_schemas_for("google")).to be_empty
    end
  end

  describe "lookup" do
    it "finds plugins by key and tolerates junk" do
      expect(Tools::Catalog.find("slack")[:name]).to eq("Slack")
      expect(Tools::Catalog.find("nope")).to be_nil
      expect(Tools::Catalog.find(nil)).to be_nil
    end

    it "resolves namespaced names with plugin context merged in" do
      tool = Tools::Catalog.tool_by_namespaced_name("slack.post_message")
      expect(tool[:plugin_key]).to eq("slack")
      expect(tool[:executor]).to eq("Integrations::Slack::PostMessage")
      expect(Tools::Catalog.tool_by_namespaced_name("slack.fly")).to be_nil
      expect(Tools::Catalog.tool_by_namespaced_name("calculator")).to be_nil
      expect(Tools::Catalog.catalog_tool?("stripe.create_payment_link")).to be(true)
      expect(Tools::Catalog.provider_for("github.list_issues")).to eq("github")
    end

    it "builds openai-style schemas and drops unknown names" do
      schemas = Tools::Catalog.schemas([ "slack.post_message", "nope.nope", "calculator" ])
      expect(schemas.map { |s| s[:name] }).to eq([ "slack.post_message" ])
      schema = schemas.first
      expect(schema[:description]).to be_present
      expect(schema[:parameters][:type]).to eq("object")
    end
  end

  describe "organization availability" do
    it "surfaces plugins only for connected + active integrations with tools" do
      slack = create(:tool_integration, organization: organization, provider: "slack")
      create(:tool_integration, organization: organization, provider: "google")
      paused = create(:tool_integration, organization: organization, provider: "github", name: "GH", credentials: { "api_key" => "ghp" })
      paused.update!(is_active: false)

      available = described_class.available_plugins(organization)
      expect(available.map { |row| row[:plugin][:key] }).to eq([ "slack" ])
      expect(available.first[:integration].id).to eq(slack.id)
      expect(described_class.available_tool_names(organization)).to eq([ "slack.post_message" ])
    end

    it "returns nothing for a nil organization" do
      expect(described_class.available_plugins(nil)).to be_empty
      expect(described_class.available_tool_names(nil)).to be_empty
    end

    it "checks connectivity by row existence" do
      expect(described_class.connected?(organization, "slack")).to be(false)
      create(:tool_integration, organization: organization, provider: "slack")
      expect(described_class.connected?(organization, "slack")).to be(true)
      expect(described_class.connected?(nil, "slack")).to be(false)
    end
  end
end
