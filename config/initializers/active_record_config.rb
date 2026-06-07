# Be sure to restart your server when you modify this file.

# Set up ActiveRecord database configurations for rake tasks.
# Rails 8.1 with selective requires needs this to ensure DatabaseTasks
# has the configuration before any db:* tasks run.
Rails.application.config.after_initialize do
  if defined?(ActiveRecord::Base) && ActiveRecord::Base.configurations.empty?
    dc = Rails.application.config.database_configuration
    ActiveRecord::Tasks::DatabaseTasks.database_configuration = dc
    ActiveRecord::Base.configurations = dc
  end
end
