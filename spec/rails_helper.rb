require "simplecov"
SimpleCov.start "rails" do
  add_filter "/test/"
  add_filter "/spec/"
  add_filter "/vendor/"
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
  Capybara::Cuprite::Driver.new(app, window_size: [1200, 800])
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
