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

  describe "deep_research result contract" do
    let(:organization) { create(:organization) }
    let(:user) { organization.owner }
    let(:url) { "https://example.com/evidence" }
    let(:source_id) { Research::DeepResearch.source_id(url) }
    let(:full_result) do
      {
        status: "completed", reason: nil, calls: [ { query: "Rails", status: "completed" } ],
        sources: [ { source_id: source_id, title: "Evidence", url: url, snippet: "x" * 2000, query: "Rails" } ],
        findings: [ { text: "x" * 2000, source_url: url, basis: "search_snippet" } ],
        limits: { sources: 10, calls: 20, seconds: 120, questions: 5, snippet_characters: 2000 },
        elapsed_seconds: 0.5, caveat: "Findings are provider search snippets; full pages have not been reviewed."
      }
    end
    let(:context) { { user: user, organization: organization } }

    before do
      allow(Capabilities::Registry).to receive(:available?).and_call_original
      allow(Capabilities::Registry).to receive(:available?).with("deep_research", organization: organization).and_return(true)
    end

    it "sends the full ledger to the runner sink and returns only bounded model output" do
      received = []
      expect(Research::DeepResearch).to receive(:call).and_return(full_result)

      result = described_class.execute("deep_research", { "topic" => "Rails" },
        context.merge(research_sink: ->(research) { received << research }))

      expect(received).to eq([ full_result ])
      expect(result[:ok]).to be(true)
      expect(result[:calls]).to eq(1)
      expect(result[:sources].first).to include(source_id: source_id, number: 1)
      expect(result[:sources].first[:snippet].length).to eq(300)
      expect(result[:findings]).to eq([ { source_id: source_id, basis: "search_snippet" } ])
      expect(result.to_json.bytesize).to be <= Research::DeepResearch::TOOL_RESULT_MAX_BYTES
    end
  end

  describe "capability gating (Phase C)" do
    before do
      allow(Sketches::Create).to receive(:available?).and_return(false)
      described_class.register_capability "cap_probe_tool", "sketch",
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
    let(:organization) { create(:organization) }
    let(:user) { organization.owner }
    let(:agent) { create(:agent, organization: organization) }
    let(:conversation) { create(:conversation, user: user, agent: agent) }
    let(:context) { { user: user, conversation_id: conversation.id, agent_id: agent.id } }

    it "refuses with capability_unavailable while no provider key is configured" do
      result = described_class.execute("generate_image", { "prompt" => "a lighthouse" }, context)

      expect(result[:ok]).to be false
      expect(result[:error_code]).to eq("capability_unavailable")
      expect(result[:capability]).to eq("image_generation")
      expect(ImageGeneration.count).to eq(0)
    end

    context "with the capability enabled" do
      before do
        allow(Capabilities::Registry).to receive(:available?).and_call_original
        allow(Capabilities::Registry).to receive(:available?).with("image_generation", organization: organization).and_return(true)
        allow(Images::GenerateJob).to receive(:perform_later)
      end

      it "queues a trimmed row tagged with the conversation and enqueues the job" do
        result = described_class.execute("generate_image", { "prompt" => "  a lighthouse at dusk  " }, context)

        expect(result[:ok]).to be true
        expect(result[:status]).to eq("queued")
        generation = ImageGeneration.find(result[:image_generation_id])
        expect(generation.prompt).to eq("a lighthouse at dusk")
        expect(generation.user_id).to eq(user.id)
        expect(generation.organization_id).to eq(organization.id)
        expect(generation.metadata["conversation_id"]).to eq(conversation.id.to_s)
        expect(Images::GenerateJob).to have_received(:perform_later).with(generation.id)
      end

      it "falls back to safe defaults for out-of-catalog size/quality" do
        result = described_class.execute(
          "generate_image",
          { "prompt" => "arctic fox", "size" => "9999x9999", "quality" => "ultra" },
          context
        )
        generation = ImageGeneration.find(result[:image_generation_id])

        expect(generation.size).to eq("1024x1024")
        expect(generation.quality).to eq("auto")
      end

      it "refuses a second generation while one is in flight for the conversation" do
        create(:image_generation, :running, user: user,
                                             metadata: { "conversation_id" => conversation.id })

        result = described_class.execute("generate_image", { "prompt" => "second one" }, context)

        expect(result[:ok]).to be false
        expect(result[:error_code]).to eq("generation_in_flight")
        expect(Images::GenerateJob).not_to have_received(:perform_later)
      end

      it "denies honestly without an acting user" do
        result = described_class.execute("generate_image", { "prompt" => "ghost art" }, {})

        expect(result[:ok]).to be false
        expect(result[:error_code]).to eq("not_authorized")
      end

      it "rejects a forged agent that does not own the conversation" do
        other_agent = create(:agent, organization: organization)
        result = described_class.execute("generate_image", { "prompt" => "forged art" },
          context.merge(agent_id: other_agent.id))

        expect(result).to eq(ok: false, error_code: "not_authorized")
        expect(ImageGeneration.count).to eq(0)
        expect(Images::GenerateJob).not_to have_received(:perform_later)
      end

      it "rejects another user's conversation" do
        foreign = create(:conversation)
        result = described_class.execute("generate_image", { "prompt" => "foreign art" },
          context.merge(conversation_id: foreign.id, agent_id: foreign.agent.id))

        expect(result).to eq(ok: false, error_code: "not_authorized")
        expect(ImageGeneration.count).to eq(0)
        expect(Images::GenerateJob).not_to have_received(:perform_later)
      end

      it "rolls back the generation when enqueueing fails" do
        allow(Images::GenerateJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError)

        expect { described_class.execute("generate_image", { "prompt" => "retry art" }, context) }
          .to raise_error(ActiveJob::EnqueueError)
        expect(ImageGeneration.count).to eq(0)
      end

      it "surfaces validation errors for a blank prompt instead of a silent row" do
        result = described_class.execute("generate_image", { "prompt" => "   " }, context)

        expect(result[:ok]).to be false
        expect(result[:error_code]).to eq("invalid_request")
        expect(result[:errors]).to be_present
        expect(ImageGeneration.count).to eq(0)
      end
    end
  end

  # The interpreter-pinned project scaffolder. Registration + delegation only
  # here; the file/interpreter logic is covered by scaffolder_spec.
  describe "scaffold" do
    it "is registered and advertised to the model" do
      tool = described_class.get("scaffold")
      expect(tool).to be_present
      expect(tool[:description]).to include("django_landing")
      expect(described_class.schemas([ "scaffold" ]).first[:parameters][:required]).to include("target_dir")
    end

    it "validates that target_dir is present before running" do
      expect { described_class.execute("scaffold", {}) }
        .to raise_error(ArgumentError, /Invalid arguments/)
    end

    it "defaults the template and delegates to Agents::Scaffolder" do
      allow(Agents::Scaffolder).to receive(:scaffold).and_return({ ok: true, project_dir: "/tmp/x" })

      result = described_class.execute("scaffold", { "target_dir" => "/tmp/x" })
      expect(result[:ok]).to be true
      expect(Agents::Scaffolder).to have_received(:scaffold).with(
        template: "django_landing", target_dir: "/tmp/x", brand: nil, force: false
      )
    end

    it "passes through template, brand and force" do
      allow(Agents::Scaffolder).to receive(:scaffold).and_return({ ok: true })

      described_class.execute("scaffold", {
        "target_dir" => "/tmp/y", "template" => "django_landing",
        "brand" => "Quasar", "force" => true
      })
      expect(Agents::Scaffolder).to have_received(:scaffold).with(
        template: "django_landing", target_dir: "/tmp/y", brand: "Quasar", force: true
      )
    end
  end
end
