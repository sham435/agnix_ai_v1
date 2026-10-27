require "rails_helper"

RSpec.describe Memory, ".nearest_to" do
  let(:user) { create(:user) }

  describe "vector validation" do
    it "accepts a valid float array" do
      vector = [0.1, -0.2, 0.3]
      # The scope itself returns a relation; it won't error on valid input
      # even if the table is empty (IVFFlat index guards handle that).
      expect { described_class.nearest_to(vector) }.not_to raise_error
    end

    it "accepts a stringified array" do
      vector = "[0.1, -0.2, 0.3]"
      expect { described_class.nearest_to(vector) }.not_to raise_error
    end

    it "rejects SQL injection via string vector" do
      expect { described_class.nearest_to("DROP TABLE users") }.to raise_error(ArgumentError)
    end

    it "rejects injection via array containing SQL" do
      expect { described_class.nearest_to(["0.1", "DROP TABLE users"]) }.to raise_error(ArgumentError)
    end

    it "rejects nil vector" do
      expect { described_class.nearest_to(nil) }.to raise_error(ArgumentError)
    end

    it "rejects non-numeric types" do
      expect { described_class.nearest_to([1, 2, "abc"]) }.to raise_error(ArgumentError)
    end

    it "rejects integer input (not an Array or String)" do
      expect { described_class.nearest_to(42) }.to raise_error(ArgumentError)
    end
  end

  describe "for_user_and_agent" do
    it "filters by user_id" do
      other_user = create(:user)
      Memory.create!(user: user, content: "my memory")
      Memory.create!(user: other_user, content: "other memory")

      results = described_class.for_user_and_agent(user.id, nil)
      expect(results.pluck(:user_id).uniq).to eq([user.id])
    end

    it "includes nil agent_id memories" do
      agent = create(:agent)
      Memory.create!(user: user, agent: agent, content: "with agent")
      Memory.create!(user: user, content: "no agent")

      results = described_class.for_user_and_agent(user.id, agent.id)
      expect(results.count).to eq(2)
    end
  end
end
