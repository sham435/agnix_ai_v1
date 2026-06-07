# Seed data for development and demo.
return unless Rails.env.development? || Rails.env.test?

puts "🌱 Seeding database..."

# Create default user.
user = User.find_or_create_by!(email: "shams@agnix.ai") do |u|
  u.name = "Shams"
  u.password = "password123"
  u.role = "admin"
  u.confirmed_at = Time.current
end

puts "  ✓ User: #{user.email}"

# Create default organization.
org = Organization.find_or_create_by!(slug: "agnix") do |o|
  o.name = "Agnix Labs"
  o.owner = user
  o.plan = "pro"
end

puts "  ✓ Organization: #{org.name}"

# Create membership.
Membership.find_or_create_by!(user: user, organization: org) do |m|
  m.role = "owner"
end

puts "  ✓ Membership created"

# Create default agents.
coding_agent = Agent.find_or_create_by!(slug: "code-assistant") do |a|
  a.organization = org
  a.name = "Code Assistant"
  a.description = "A helpful coding assistant that writes, reviews, and explains code."
  a.system_prompt = <<~PROMPT
    You are an expert software engineer specializing in Ruby on Rails, modern web development,
    and AI-powered coding assistance. You write clean, well-tested, production-ready code.

    Guidelines:
    - Always explain your reasoning briefly before showing code.
    - Use modern Rails 8.1 patterns: Hotwire, Turbo, Stimulus, Solid Queue.
    - Follow Ruby best practices and idiomatic patterns.
    - Include error handling and edge cases.
    - Suggest tests when appropriate.
  PROMPT
  a.model = "claude-sonnet-4-6"
  a.provider = "anthropic"
  a.tools = ["calculator", "memory_search", "time"]
  a.config = { temperature: 0.7, max_tokens: 4096 }
  a.is_active = true
end

puts "  ✓ Agent: #{coding_agent.name}"

research_agent = Agent.find_or_create_by!(slug: "research-agent") do |a|
  a.organization = org
  a.name = "Research Agent"
  a.description = "An agent specialized in research, analysis, and summarization."
  a.system_prompt = <<~PROMPT
    You are a research specialist that helps with deep analysis, fact-checking, and synthesis.
    You provide well-structured, sourced responses with clear reasoning.

    Guidelines:
    - Break down complex topics systematically.
    - Cite sources when available.
    - Distinguish between facts, analysis, and speculation.
    - Provide executive summaries for long responses.
  PROMPT
  a.model = "claude-opus-4-8"
  a.provider = "anthropic"
  a.tools = ["web_search", "memory_search", "time"]
  a.config = { temperature: 0.5, max_tokens: 8192 }
  a.is_active = true
end

puts "  ✓ Agent: #{research_agent.name}"

# Create a demo conversation.
conversation = Conversation.find_or_create_by!(id: "00000000-0000-0000-0000-000000000001") do |c|
  c.user = user
  c.agent = coding_agent
  c.title = "Getting started with Rails 8.1"
end

Message.find_or_create_by!(conversation: conversation, role: "user", content: "How do I set up a new Rails 8.1 project with Solid Queue?") do |m|
  m.tokens = 15
end

Message.find_or_create_by!(conversation: conversation, role: "assistant", content: <<~RESPONSE)
  Setting up a Rails 8.1 project with Solid Queue is straightforward since it's built in! Here's how:

  ```bash
  rails new myapp --database=postgresql --javascript=importmap --css=tailwind
  cd myapp
  ```

  Solid Queue is enabled by default in Rails 8.1. You just need to run the migrations:

  ```bash
  bin/rails solid_queue:install
  bin/rails db:migrate
  ```

  Then start your app with the queue running:

  ```bash
  bin/dev  # runs web server + Solid Queue via Procfile.dev
  ```

  Want me to show you how to create your first background job?
RESPONSE

puts "  ✓ Demo conversation created"

# Create demo memories.
Memory.find_or_create_by!(content: "User prefers Ruby on Rails for web development projects.",
  user: user, agent: coding_agent, source_type: "conversation", source_id: conversation.id)

puts "  ✓ Demo memories created"

puts "\n✅ Seeding complete!"
puts "   Login: #{user.email} / password123"
