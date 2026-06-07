# Usage Report Job - Reports token usage to Stripe for metered billing.
class UsageReportJob < ApplicationJob
  queue_as :default

  def perform(run_id)
    run = Run.find(run_id)
    return unless run.completed?

    tokens = run.tokens_used || run.output&.dig("tokens") || 0
    return if tokens == 0

    # Estimate cost (approximate - adjust for your pricing model).
    cost_cents = (tokens * 0.0003).ceil # ~$3 per 1M tokens.

    StripeService.report_usage(
      run.agent.organization_id,
      tokens: tokens,
      cost_cents: cost_cents,
      event_type: "chat_completion",
      run_id: run.id
    )
  end
end
