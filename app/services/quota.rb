# frozen_string_literal: true

# Daily token budget per organization.
#
# The ledger is `usage_events`, which already existed but nothing ever wrote:
# a turn reserves its worst-case cost before the model is called and is settled
# with the real number afterwards, so two turns running at the same moment
# cannot both spend the last of the day's allowance.
class Quota
  # Ceiling by plan. nil means unmetered — the owner's own workspace and the
  # beta orgs keep behaving exactly as they did before this class existed, and
  # `pro` is the allowance a Coffee Key buys for 90 days.
  DAILY_TOKENS = { "free" => nil, "pro" => 20_000, "enterprise" => nil }.freeze

  # Prompt overhead the runner adds around the user's own text: system prompt,
  # history, tool schemas. Deliberately rough — it sizes a reservation, not a
  # bill, and the settled actual replaces it as soon as the turn finishes.
  CONTEXT_TOKENS = 2_048

  # Characters per token, the usual rule of thumb for English prose.
  CHARS_PER_TOKEN = 4

  # What one organization has left of its daily budget. `cap` and `remaining`
  # are nil for unmetered plans — the panel reads that as "no daily ceiling",
  # never as zero.
  Summary = Struct.new(:plan, :cap, :used, :remaining, keyword_init: true) do
    def metered? = !cap.nil?
  end

  class Exceeded < StandardError
    attr_reader :cap, :used

    def initialize(cap:, used:)
      @cap = cap
      @used = used
      super("You have used all #{cap} tokens for today. Try again tomorrow, or upgrade for a higher daily allowance.")
    end

    # Surfaces as the terminal frame's machine-readable cause in AgentStreamJob.
    def code = :quota_exceeded
  end

  class << self
    def cap_for(organization)
      return nil if organization.nil?

      DAILY_TOKENS[organization.plan]
    end

    def used_today(organization)
      return 0 if organization.nil?

      UsageEvent.where(organization_id: organization.id)
        .where(created_at: Time.current.all_day)
        .sum(:tokens)
    end

    def remaining(organization)
      cap = cap_for(organization)
      return nil if cap.nil?

      cap - used_today(organization)
    end

    # Everything the account panel's "Usage & membership" section shows, in one
    # read: a view that called cap_for/used_today/remaining separately would run
    # the ledger sum three times and could report numbers from three moments.
    def summary_for(organization)
      cap = cap_for(organization)
      used = used_today(organization)

      Summary.new(
        plan: organization&.plan || "free",
        cap: cap,
        used: used,
        remaining: cap.nil? ? nil : cap - used
      )
    end

    # Worst-case cost of one turn: the prompt we are about to send plus the
    # agent's full output cap (4096 is what Llm::Client falls back to when the
    # agent has no `max_tokens` configured — see Agent#llm_client).
    def estimate(agent, content)
      prompt = (content.to_s.length.to_f / CHARS_PER_TOKEN).ceil + CONTEXT_TOKENS
      output = (agent.respond_to?(:max_tokens) ? agent.max_tokens : nil).to_i
      prompt + (output.positive? ? output : 4_096)
    end

    # Returns the ledger row to settle, or nil when there is nothing to meter.
    # Raises Quota::Exceeded when the turn would not fit in what is left today.
    def reserve(organization, estimate:, event_type: "chat_completion")
      return nil if organization.nil?

      cap = cap_for(organization)
      if cap && used_today(organization) + estimate > cap
        raise Exceeded.new(cap: cap, used: used_today(organization))
      end

      UsageEvent.create!(
        organization: organization,
        event_type: event_type,
        tokens: estimate,
        metadata: { "state" => "reserved", "cap" => cap, "estimated_at" => Time.current.utc.iso8601 }
      )
    end

    # Replace a reservation with what the turn really cost. A turn that never
    # reported a number — a crash, a run killed mid-flight — keeps its
    # reservation, so a failure cannot be turned into free inference.
    def settle(reservation, actual:)
      return if reservation.nil? || actual.nil?

      metadata = reservation.metadata.dup
      metadata["state"] = "settled"
      metadata["settled_at"] = Time.current.utc.iso8601

      reservation.update!(tokens: [ actual.to_i, 0 ].max, metadata: metadata)
    end
  end
end
