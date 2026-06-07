namespace :counters do
  desc "Reset all counter cache columns"
  task reset: :environment do
    puts "Resetting conversation.messages_count..."
    Conversation.find_each do |c|
      count = c.messages.count
      c.update_column(:messages_count, count)
    end

    puts "Resetting agent.runs_count..."
    Agent.find_each do |a|
      count = a.runs.count
      a.update_column(:runs_count, count)
    end

    puts "Resetting organization.conversations_count..."
    Organization.find_each do |o|
      count = Conversation.joins(:agent).where(agents: { organization_id: o.id }).count
      o.update_column(:conversations_count, count)
    end

    puts "All counters reset."
  end
end
