FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@agnix.ai" }
    name { "Test User" }
    password { "password123" }
    role { "user" }
    confirmed_at { Time.current }

    trait :admin do
      role { "admin" }
    end

    trait :confirmed do
      confirmed_at { Time.current }
    end
  end

  factory :organization do
    sequence(:name) { |n| "Org #{n}" }
    sequence(:slug) { |n| "org-#{n}" }
    association :owner, factory: :user
    plan { "free" }

    trait :pro do
      plan { "pro" }
    end
  end

  factory :membership do
    association :user
    association :organization
    role { "member" }

    trait :admin do
      role { "admin" }
    end

    trait :owner do
      role { "owner" }
    end
  end

  factory :agent do
    sequence(:name) { |n| "Agent #{n}" }
    sequence(:slug) { |n| "agent-#{n}" }
    association :organization
    system_prompt { "You are a helpful AI assistant." }
    model { "claude-sonnet-4-6" }
    provider { "anthropic" }
    tools { ["calculator", "time"] }
    config { { temperature: 0.7, max_tokens: 4096 } }
    is_active { true }

    trait :opus do
      model { "claude-opus-4-8" }
    end

    trait :openai do
      provider { "openai" }
      model { "gpt-4o" }
    end

    trait :inactive do
      is_active { false }
    end
  end

  factory :conversation do
    association :user
    association :agent
    title { "Test conversation" }
    status { "active" }
  end

  factory :message do
    association :conversation
    role { "user" }
    content { "Hello, this is a test message." }
    tokens { 10 }

    trait :assistant do
      role { "assistant" }
    end

    trait :with_tools do
      role { "assistant" }
      tool_calls { [{ id: "call_1", type: "function", function: { name: "calculator", arguments: '{"expression": "2+2"}' } }] }
    end
  end

  factory :memory do
    association :user
    content { "Test memory content" }
    source_type { "conversation" }

    trait :with_embedding do
      embedding { Array.new(1536) { rand(-1.0..1.0) } }
    end
  end

  factory :tool_integration do
    association :organization
    provider { "stripe" }
    name { "Stripe" }
    credentials { { api_key: "sk_test_123", webhook_secret: "whsec_test" } }
    config { {} }
    is_active { true }
  end

  factory :run do
    association :agent
    input { { query: "Test query" } }
    status { "pending" }
    tokens_used { 0 }

    trait :running do
      status { "running" }
      started_at { Time.current }
    end

    trait :completed do
      status { "completed" }
      output { { content: "Test response", tokens: 100 } }
      tokens_used { 100 }
      started_at { 5.minutes.ago }
      finished_at { Time.current }
    end

    trait :failed do
      status { "failed" }
      error_message { "Test error" }
      started_at { 5.minutes.ago }
      finished_at { Time.current }
    end
  end

  factory :subscription do
    association :organization
    stripe_id { "sub_test123" }
    status { "active" }
    current_period_start { Time.current }
    current_period_end { 1.month.from_now }
  end

  factory :invoice do
    association :organization
    stripe_id { "in_test123" }
    amount { 1000 }
    currency { "usd" }
    status { "paid" }
  end

  factory :usage_event do
    association :organization
    event_type { "chat_completion" }
    tokens { 500 }
    cost_cents { 15 }
  end

  factory :agent_run do
    association :conversation
    mode { "auto_plan" }
    status { "planning" }
    reasoning_steps { [] }
  end

  factory :agent_todo do
    association :agent_run
    title { "Do something" }
    status { "pending" }
    position { 0 }
  end
end
