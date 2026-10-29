# spec/db/seeds_spec.rb

# Narrative seed spec: several assertions per example by design, and it drives
# the real db/seeds.rb inside the example's transaction (rolled back). There is
# no class under test, so DescribeClass is intentionally not applicable here.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/DescribeClass

require "rails_helper"

RSpec.describe "db/seeds.rb" do
  def scaffold_entries(slug)
    Agent.find_by(slug: slug)&.tools&.count do |t|
      (t.is_a?(Hash) ? (t["name"] || t[:name]) : t).to_s == "scaffold"
    end
  end

  it "grants the chat agent scaffold exactly once, even on repeat seeds and legacy rows" do
    seed = Rails.root.join("db/seeds.rb")

    # Fresh install: the create block itself already lists scaffold.
    load seed
    expect(scaffold_entries("shams-ai")).to eq(1)

    # Simulate an agent row seeded before the scaffold tool existed.
    legacy = Agent.find_by(slug: "shams-ai")
    legacy.update!(tools: legacy.tools - [ "scaffold" ])
    expect(scaffold_entries("shams-ai")).to eq(0)

    # Re-seeding upgrades that row in place ...
    load seed
    expect(scaffold_entries("shams-ai")).to eq(1)

    # ... and stays idempotent while preserving the existing tool order.
    load seed
    expect(scaffold_entries("shams-ai")).to eq(1)
    expect(Agent.find_by(slug: "shams-ai").tools).to eq([ "calculator", "memory_search", "time", "scaffold" ])
  end
end
