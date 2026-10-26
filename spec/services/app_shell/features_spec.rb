# spec/services/app_shell/features_spec.rb

# Phase 5d — Route-driven nav slots must light up exactly when a phase mounts
# its route and stay dark otherwise (the shell forbids dead links). With Phases
# 2/3/5 landed, every curated slot is built, so the "unbuilt" half is proven
# against a stubbed path that no route serves.
# rubocop:disable RSpec/MultipleExpectations

require "rails_helper"

RSpec.describe AppShell::Features, type: :service do
  it "surfaces each slot whose route is mounted" do
    expect(described_class.enabled?(:scheduled)).to be(true)
    expect(described_class.enabled?(:images)).to be(true)
    expect(described_class.enabled?(:explore)).to be(true)
    expect(described_class.disabled?(:explore)).to be(false)
  end

  it "hides a slot whose route has not been mounted yet" do
    stub_const("AppShell::Features::REQUIRED_PATHS", { scheduled: "/scheduled", widgets: "/widgets" })

    expect(described_class.enabled?(:widgets)).to be(false)
    expect(described_class.disabled?(:widgets)).to be(true)
    expect(described_class.enabled?(:scheduled)).to be(true)
  end

  it "returns false for a key it has never curated" do
    expect(described_class.enabled?(:billing)).to be(false)
    expect(described_class.enabled?(:plugins)).to be(false)
  end
end
