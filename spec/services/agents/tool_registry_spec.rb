# spec/services/agents/tool_registry_spec.rb

# Narrative registry specs: several assertions per example by design.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MessageSpies, RSpec/StubbedMock, RSpec/MultipleMemoizedHelpers

require "rails_helper"

RSpec.describe Agents::ToolRegistry, type: :service do
  describe ".register" do
    it "registers a new tool" do
      described_class.register "test_tool",
        description: "A test tool",
        parameters: { type: "object", properties: { input: { type: "string" } }, required: [ "input" ] } do |args|
        { result: args["input"] }
      end

      expect(described_class.get("test_tool")).to be_present
    end
  end

  describe ".execute" do
    it "executes a registered tool with valid arguments" do
      result = described_class.execute("calculator", { "expression" => "2+2" })
      expect(result[:result]).to eq(4)
    end

    it "raises error for unknown tool" do
      expect { described_class.execute("nonexistent", {}) }
        .to raise_error(ArgumentError, /Unknown tool/)
    end

    it "validates required arguments" do
      expect { described_class.execute("web_search", {}) }
        .to raise_error(ArgumentError, /Invalid arguments/)
    end

    it "returns time correctly" do
      result = described_class.execute("time", {})
      expect(result[:time]).to be_present
    end
  end

  describe ".schemas" do
    it "returns tool schemas for LLM function calling" do
      schemas = described_class.schemas([ "calculator" ])
      expect(schemas.first[:name]).to eq("calculator")
      expect(schemas.first[:description]).to be_present
      expect(schemas.first[:parameters]).to be_present
    end
  end

  describe "capability gating (Phase C)" do
    before do
      described_class.register_capability "cap_probe_tool", "sketch", # sketch = disabled("planned")
        description: "Probe",
        parameters: { type: "object", properties: {} } do |_args, _context|
        raise "capability gate must prevent execution"
      end
    end

    it "returns a bounded refusal instead of executing for disabled capabilities" do
      result = described_class.execute("cap_probe_tool", {})
      expect(result[:ok]).to be false
      expect(result[:error_code]).to eq("capability_unavailable")
      expect(result[:capability]).to eq("sketch")
    end

    it "exposes the capability key mapping" do
      expect(described_class.capability_key_for("cap_probe_tool")).to eq("sketch")
      expect(described_class.capability_key_for("time")).to be_nil
      expect(described_class.capability_key_for("read_asset")).to eq("file_extraction")
      expect(described_class.capability_key_for("list_assets")).to eq("library")
    end

    it "keeps read_file and the file_reader alias on the same executor" do
      expect(described_class.get("read_file")).to be_present
      expect(described_class.get("file_reader")).to be_present
    end

    it "documents missing indexes for argument validation before any execution" do
      expect { described_class.execute("read_asset", {}) }
        .to raise_error(ArgumentError, /Invalid arguments/)
    end
  end

  describe "read_asset (file_extraction capability)" do
    let(:user) { create(:user) }
    let(:asset) { create(:asset, user: user, filename: "notes.txt") }

    def run_read_asset(args, context)
      described_class.execute("read_asset", args, context)
    end

    it "denies honestly when no acting user is present" do
      result = run_read_asset({ "asset_id" => asset.id }, {})
      expect(result[:ok]).to be false
      expect(result[:error_code]).to eq("not_authorized")
    end

    it "refuses foreign assets (ownership enforced via readable_by?)" do
      other = create(:user)
      result = run_read_asset({ "asset_id" => asset.id }, { user: other })
      expect(result[:ok]).to be false
      expect(result[:error_code]).to eq("not_authorized")
    end

    it "resolves user_id-only context and returns completed content" do
      create(:asset_extraction, asset: asset, status: "completed", content: "extracted body", meta: { "pages" => 1 })
      result = run_read_asset({ "asset_id" => asset.id }, { user_id: user.id })

      expect(result[:ok]).to be true
      expect(result[:asset]).to eq("notes.txt")
      expect(result[:status]).to eq("completed")
      expect(result[:content]).to eq("extracted body")
      expect(result[:truncated]).to be false
    end

    it "reports failed extraction through its safe error code" do
      create(:asset_extraction, asset: asset, status: "failed", error_code: "corrupt_document")
      result = run_read_asset({ "asset_id" => asset.id }, { user: user })

      expect(result[:ok]).to be false
      expect(result[:error_code]).to eq("corrupt_document")
    end

    it "reports in-progress extraction without fabricating text" do
      create(:asset_extraction, asset: asset, status: "processing", content: nil)
      result = run_read_asset({ "asset_id" => asset.id }, { user: user })

      expect(result[:ok]).to be true
      expect(result[:status]).to eq("processing")
      expect(result[:content]).to be_nil
    end

    it "honors the thousand..twenty-thousand char bound" do
      create(:asset_extraction, asset: asset, status: "completed", content: "x" * 2500)
      result = run_read_asset({ "asset_id" => asset.id, "max_chars" => 1000 }, { user: user })

      expect(result[:content].length).to eq(1000)
      expect(result[:truncated]).to be true
      expect(result[:total_chars]).to eq(2500)
    end
  end

  describe "list_assets (library capability)" do
    let(:user) { create(:user) }

    it "lists the acting user's recent assets with honest extraction states" do
      old = create(:asset, user: user, filename: "old.txt")
      fresh = create(:asset, user: user, filename: "new.txt")
      create(:asset_extraction, asset: fresh, status: "completed", content: "body")

      result = described_class.execute("list_assets", {}, { user: user })
      ids = result[:assets].map { |a| a[:id] }

      expect(result[:ok]).to be true
      expect(ids).to contain_exactly(old.id, fresh.id)
      expect(ids.first).to eq(fresh.id) # most recent first
      extraction_states = result[:assets].map { |a| a[:extraction_status] }
      expect(extraction_states).to contain_exactly(nil, "completed")
    end

    it "denies honestly without an acting user" do
      result = described_class.execute("list_assets", {}, {})
      expect(result[:ok]).to be false
      expect(result[:error_code]).to eq("not_authorized")
    end

    it "caps the limit at 25" do
      Array.new(27) { create(:asset, user: user) }
      result = described_class.execute("list_assets", { "limit" => 27 }, { user: user })
      expect(result[:assets].length).to eq(25)
    end
  end

  # Phase 3 — the in-chat generate_image tool. Test env keeps image_generation
  # at needs_authorization, so the refusal path needs no stubbing at all; the
  # happy paths flip only the availability gate and never hit real HTTP.
  describe "generate_image (image_generation capability)" do
    let(:user) { create(:user) }
    let(:conversation) { create(:conversation, user: user) }

    it "refuses with capability_unavailable while no provider key is configured" do
      result = described_class.execute("generate_image", { "prompt" => "a lighthouse" },
                                       { user: user, conversation_id: conversation.id })

      expect(result[:ok]).to be false
      expect(result[:error_code]).to eq("capability_unavailable")
      expect(result[:capability]).to eq("image_generation")
      expect(ImageGeneration.count).to eq(0)
    end

    context "with the capability enabled" do
      before do
        allow(Capabilities::Registry).to receive(:available?).and_call_original
        allow(Capabilities::Registry).to receive(:available?).with("image_generation").and_return(true)
        allow(Images::GenerateJob).to receive(:perform_later)
      end

      it "queues a trimmed row tagged with the conversation and enqueues the job" do
        result = described_class.execute("generate_image", { "prompt" => "  a lighthouse at dusk  " },
                                         { user: user, conversation_id: conversation.id })

        expect(result[:ok]).to be true
        expect(result[:status]).to eq("queued")
        generation = ImageGeneration.find(result[:image_generation_id])
        expect(generation.prompt).to eq("a lighthouse at dusk")
        expect(generation.user_id).to eq(user.id)
        expect(generation.metadata["conversation_id"]).to eq(conversation.id.to_s)
        expect(Images::GenerateJob).to have_received(:perform_later).with(generation.id)
      end

      it "falls back to safe defaults for out-of-catalog size/quality" do
        result = described_class.execute(
          "generate_image",
          { "prompt" => "arctic fox", "size" => "9999x9999", "quality" => "ultra" },
          { user: user }
        )
        generation = ImageGeneration.find(result[:image_generation_id])

        expect(generation.size).to eq("1024x1024")
        expect(generation.quality).to eq("auto")
      end

      it "refuses a second generation while one is in flight for the conversation" do
        create(:image_generation, :running, user: user,
                                             metadata: { "conversation_id" => conversation.id })

        result = described_class.execute("generate_image", { "prompt" => "second one" },
                                         { user: user, conversation_id: conversation.id })

        expect(result[:ok]).to be false
        expect(result[:error_code]).to eq("generation_in_flight")
        expect(Images::GenerateJob).not_to have_received(:perform_later)
      end

      it "denies honestly without an acting user" do
        result = described_class.execute("generate_image", { "prompt" => "ghost art" }, {})

        expect(result[:ok]).to be false
        expect(result[:error_code]).to eq("not_authorized")
      end

      it "surfaces validation errors for a blank prompt instead of a silent row" do
        result = described_class.execute("generate_image", { "prompt" => "   " }, { user: user })

        expect(result[:ok]).to be false
        expect(result[:error_code]).to eq("invalid_request")
        expect(result[:errors]).to be_present
        expect(ImageGeneration.count).to eq(0)
      end
    end
  end
end
