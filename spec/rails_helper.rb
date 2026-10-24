require "simplecov"

# Per-group coverage gate (SimpleCov dropped per-group minimums in 0.19, so
# this small exit hook enforces them). Active only on full runs started with
# COVERAGE_GATE=1 so targeted single-file runs don't falsely fail.
def shams_group_coverage_gate(name, minimum)
  group = SimpleCov.result.groups[name]
  return warn("[coverage] group '#{name}' expected by the coverage gate but missing") if group.nil?

  measured = group.covered_percent.round(2)
  return if measured >= minimum

  abort("[coverage] group '#{name}' below minimum: #{measured}% < #{minimum}%")
end

SimpleCov.start "rails" do
  enable_coverage :branch
  primary_coverage :line

  add_filter "/test/"
  add_filter "/spec/"
  add_filter "/vendor/"

  add_group "Asset Pipeline", "app/services/assets"
  add_group "Asset Extraction", "app/jobs/asset_extraction_job.rb"

  # Overall line floor: 67% (measured 68.12% on the 243-example suite).
  minimum_coverage 67.0

  at_exit do
    SimpleCov.result.format!
    if ENV["SHAMS_REPORT_GROUPS"] == "1"
      # Env-gated diagnostics for the coverage gates (not test output).
      # rubocop:disable RSpec/Output
      SimpleCov.result.groups.sort_by { |_name, group| -group.covered_percent }.each do |name, group|
        puts "[coverage] #{name}: #{group.covered_percent.round(2)}% (#{group.length} file(s))"
      end
      puts "[coverage] TOTAL line: #{SimpleCov.result.covered_percent.round(2)}%"
      # rubocop:enable RSpec/Output
    end
    if ENV["COVERAGE_GATE"] == "1"
      # Group floors sit just under measured (Pipeline 95.03%, Extraction
      # 94.74%) so ordinary churn doesn't flip gates — but real drops do.
      # Env overrides (SHAMS_MIN_PIPELINE / SHAMS_MIN_EXTRACTION) allow CI to
      # tighten these, or tests to provoke the failure path.
      shams_group_coverage_gate("Asset Pipeline", ENV.fetch("SHAMS_MIN_PIPELINE", "92").to_f)
      shams_group_coverage_gate("Asset Extraction", ENV.fetch("SHAMS_MIN_EXTRACTION", "92").to_f)
    end
  end
end

require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"

# Prevent database truncation if wrong environment.
abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"
require "factory_bot_rails"
require "webmock/rspec"
require "shoulda/matchers"
require "capybara/rspec"
require "capybara/rails"
require "capybara/cuprite"

# Configure WebMock.
WebMock.disable_net_connect!(allow_localhost: true)

# Configure Shoulda Matchers.
Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end

# Include ActiveSupport time helpers for travel_to/freeze_time.
RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers
end

# Configure Capybara.
Capybara.server = :puma, { Silent: true }
Capybara.javascript_driver = :cuprite
Capybara.register_driver(:cuprite) do |app|
  Capybara::Cuprite::Driver.new(app, window_size: [ 1200, 800 ])
end

# Configure FactoryBot.
RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods

  # Use transactional fixtures.
  config.use_transactional_fixtures = true

  # Infer spec type from file location.
  config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!

  # Focus individual specs with `fit`.
  config.filter_run_when_matching :focus

  # Use Cuprite for system specs (Chrome DevTools Protocol instead of chromedriver).
  config.before(:each, type: :system) do
    driven_by(:cuprite)
  end
end

require_relative "support/login_helper"
require_relative "support/api_login_helper"
require_relative "support/assets_fixtures"
require_relative "support/composer_test_helpers"
