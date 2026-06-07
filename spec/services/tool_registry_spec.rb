require "rails_helper"

RSpec.describe Agents::ToolRegistry, type: :service do
  describe ".register" do
    it "registers a new tool" do
      described_class.register "test_tool",
        description: "A test tool",
        parameters: { type: "object", properties: { input: { type: "string" } }, required: ["input"] } do |args|
        { result: args["input"] }
      end

      expect(described_class.get("test_tool")).to be_present
    end
  end

  describe ".execute" do
    it "executes a registered tool with valid arguments" do
      result = Agents::ToolRegistry.execute("calculator", { expression: "2+2" })
      expect(result[:result]).to eq(4)
    end

    it "raises error for unknown tool" do
      expect { Agents::ToolRegistry.execute("nonexistent", {}) }
        .to raise_error(ArgumentError, /Unknown tool/)
    end

    it "validates required arguments" do
      expect { Agents::ToolRegistry.execute("web_search", {}) }
        .to raise_error(ArgumentError, /Missing required/)
    end

    it "returns time correctly" do
      result = Agents::ToolRegistry.execute("time", {})
      expect(result[:time]).to be_present
    end
  end

  describe ".schemas" do
    it "returns tool schemas for LLM function calling" do
      schemas = Agents::ToolRegistry.schemas(["calculator"])
      expect(schemas.first[:name]).to eq("calculator")
      expect(schemas.first[:description]).to be_present
      expect(schemas.first[:parameters]).to be_present
    end
  end
end
