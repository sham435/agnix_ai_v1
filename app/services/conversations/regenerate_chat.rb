# frozen_string_literal: true

# The single code path for "regenerate the last reply", shared by
# ConversationsController#regenerate (the header and per-message Regenerate
# buttons) and StreamingChannel#regenerate_last_response — the same "one startup
# path" rule Conversations::StartChat exists for.
#
# Two rules this class is here to enforce:
#
#   1. History is never destroyed up front. The old reply stays on disk until
#      the new one actually landed: the controller used to call
#      `last_assistant.destroy!` BEFORE enqueueing, so any failed run (provider
#      error, deadlock, timeout) left the thread with its answer gone — and
#      because every click destroyed one more assistant row, two clicks looked
#      like "regenerate cleared the whole chat". The row is only *marked* here
#      (handed to the job as replaces_message_id) and retired by AgentStreamJob
#      once a real answer is persisted.
#
#   2. One live run per conversation. Both controls are `data-turbo-method`
#      links, and a re-fired submission (double click, Turbo restoring its
#      cached form) used to enqueue two concurrent AgentStreamJobs on one
#      thread, fighting over the same rows. The claim is the streaming
#      placeholder itself, created inside a locked transaction, so a second
#      click sees it and backs off.
module Conversations
  module RegenerateChat
    # status: :queued (a run was enqueued) | :busy (a live run owns the thread)
    #         | :empty (there is nothing to regenerate)
    Outcome = Struct.new(:status, :message, keyword_init: true)

    # How many of the newest assistant rows the live-run probe inspects. A
    # placeholder older than Message::STREAMING_TIMEOUT counts as stale (its job
    # died without finalizing), so a dead run can never lock the thread out of
    # regeneration forever.
    LIVE_PROBE_LIMIT = 5

    QUEUED = "Regenerating response..."
    BUSY = "A response is still being generated — try again once it finishes."
    NOTHING_TO_REGENERATE = "Nothing to regenerate."
    NO_SOURCE_MESSAGE = "No user message to regenerate from."

    class << self
      def call(conversation:, user:)
        decision = conversation.with_lock do
          if live_placeholder(conversation)
            { status: :busy, message: BUSY }
          else
            decide(conversation)
          end
        end

        return Outcome.new(status: decision[:status], message: decision[:message]) if decision[:message]

        # Enqueued outside the lock: a job the surrounding transaction could
        # still roll back would point at a placeholder that never existed.
        AgentStreamJob.perform_later(
          conversation_id: conversation.id,
          user_id: user.id,
          message_content: decision[:content],
          request_id: decision[:request_id],
          replaces_message_id: decision[:supersedes]
        )

        Outcome.new(status: :queued, message: QUEUED)
      end

      private

      # Inside the conversation row lock, so nothing concurrent can slip a
      # second run (or another placeholder) in between the probe and the claim.
      def decide(conversation)
        # `.last` on these relations ordered by the uuid primary key, so it
        # picked a random row instead of the newest one — a regenerate could
        # answer a question from the middle of the thread. Order explicitly.
        superseded = newest(conversation, "assistant")
        source = newest(conversation, "user")

        if superseded.nil?
          return { status: :empty, message: NOTHING_TO_REGENERATE }
        elsif source.nil?
          return { status: :empty, message: NO_SOURCE_MESSAGE }
        end

        # Provision the placeholder here (not in the job) so it doubles as the
        # claim: it is committed before the job exists, the redirected show page
        # renders the thinking bubble immediately, and AgentStreamJob reuses this
        # exact row through request_id instead of creating a second one — the
        # StartChat contract.
        request_id = SecureRandom.uuid
        conversation.messages.create!(
          role: "assistant",
          content: "",
          metadata: {
            "streaming" => true,
            "stream_started_at" => Time.current.utc.iso8601,
            "request_id" => request_id
          }
        )

        {
          status: :queued,
          content: source.content,
          request_id: request_id,
          supersedes: superseded.id
        }
      end

      def newest(conversation, role)
        conversation.messages.where(role: role).order(created_at: :desc, id: :desc).first
      end

      def live_placeholder(conversation)
        conversation.messages.where(role: "assistant")
                    .where("metadata->>'streaming' = 'true'")
                    .order(created_at: :desc)
                    .limit(LIVE_PROBE_LIMIT)
                    .find { |message| !message.stale_streaming? }
      end
    end
  end
end
