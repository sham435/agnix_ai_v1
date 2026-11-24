# frozen_string_literal: true

module Conversations
  class TurnAdmission
    QUEUE_KEY = "m18_followups"
    STEERING_KEY = "m18_steering"
    STEERING_IDS_KEY = "steering_request_ids"
    MAX_PENDING = 20
    CLAIM_TIMEOUT = 50.minutes
    LIVE_PROBE_LIMIT = 5
    MAX_STEERING_RECEIPTS = 100

    Outcome = Struct.new(:status, :message, :request_id, :queued_count, :errors, keyword_init: true)

    class << self
      def call(conversation:, user:, params:, requested_mode: nil)
        selection = Llm::ModelSelection.new(user: user, organization: conversation.agent.organization,
          conversation: conversation).snapshot
        input = normalize_input(params, selection)
        decision = conversation.with_lock { admit(conversation, user, input, requested_mode) }
        outcome = Outcome.new(**decision)
        broadcast_tasks(conversation)
        outcome
      end

      def dispatch_next(conversation:, user:)
        defer_steering(conversation)
        return nil if active_record?(conversation)

        decision = conversation.with_lock { dequeue(conversation, user) }
        outcome = decision && Outcome.new(**decision)
        broadcast_tasks(conversation)
        outcome
      end

      def consume_steering(conversation)
        conversation.with_lock do
          meta = conversation.metadata.is_a?(Hash) ? conversation.metadata.dup : {}
          entries = Array(meta[STEERING_KEY]).select { |entry| entry.is_a?(Hash) }
          if entries.any?
            request_ids = entries.filter_map { |entry| entry["client_request_id"].to_s.presence }
            meta = merge_steering_receipts(meta, request_ids)
            conversation.update_column(:metadata, meta.except(STEERING_KEY))
          end
          entries.map { |entry| entry["content"].to_s }.reject(&:blank?)
        end
      end

      def publish_tasks(conversation)
        broadcast_tasks(conversation)
      end

      def task_summary(conversation)
        live = live_placeholder(conversation)
        runs = conversation.runs.active.order(created_at: :desc).to_a
        plans = conversation.agent_runs.active.order(created_at: :desc).to_a
        active = runs.map { |run| task_for_run(run) } + plans.map { |plan| task_for_plan(plan, conversation) }
        visible_live = live unless live&.metadata&.dig("stop_requested")
        active << task_from_placeholder(visible_live, conversation) if visible_live && active.empty?

        {
          active: active.size,
          queued: pending_count(conversation),
          active_request_id: active_request_id(active, visible_live),
          tasks: active + pending_tasks(conversation) + recent_tasks(conversation, active)
        }
      end

      def live_placeholder(conversation)
        conversation.messages.where(role: "assistant")
          .where("metadata->>'streaming' = 'true'")
          .order(created_at: :desc).limit(LIVE_PROBE_LIMIT)
          .find { |message| live?(message) }
      end

      private

      def normalize_input(params, selection)
        params = params.deep_symbolize_keys if params.respond_to?(:deep_symbolize_keys)
        content = params[:content].to_s
        asset_ids = Array(params[:attachment_asset_ids]).first(Message::MAX_ATTACHMENTS).map(&:to_s).uniq
        tools = Array(params[:tools]).first(128).map(&:to_s).map(&:strip).reject(&:blank?).uniq
        {
          content: content,
          client_request_id: params[:client_request_id].to_s.strip,
          attachment_asset_ids: asset_ids,
          attachment_draft_token: params[:attachment_draft_token].to_s.strip,
          tools: tools,
          selected_model: selection
        }
      end

      def active_record?(conversation)
        conversation.runs.active.exists? || conversation.agent_runs.active.exists?
      end

      def active_request_id(tasks, live)
        tasks.filter_map { |task| task[:request_id] }.first || live&.metadata&.dig("request_id")
      end

      def task_from_placeholder(message, conversation)
        {
          id: "message-#{message.id}", kind: "response", name: "Shams AI response",
          conversation_id: conversation.id, conversation_title: conversation.title,
          agent_name: conversation.agent.name, state: "running", progress: nil,
          started_at: message.stream_started_at&.iso8601, terminal_status: nil,
          request_id: message.metadata["request_id"], preview: nil,
          actions: [ "stop", "view" ], path: Rails.application.routes.url_helpers.conversation_path(conversation)
        }
      end

      def task_for_run(run)
        active = %w[pending running].include?(run.status)
        state = if !active
                  terminal_state(run.status)
        elsif run.status == "pending"
                  "queued"
        elsif run.metadata.is_a?(Hash) && run.metadata.dig("pcb", "current_state") == "blocked"
                  "waiting_for_tool"
        else
                  "running"
        end
        {
          id: run.id, kind: "run", name: "Agent response",
          conversation_id: run.conversation_id, conversation_title: run.conversation.title,
          agent_name: run.agent.name, state: state, progress: nil,
          started_at: (run.started_at || run.created_at)&.iso8601,
          terminal_status: active ? nil : state, request_id: run.request_id, preview: nil,
          actions: (active ? [ "stop" ] : []) + [ "view" ],
          path: Rails.application.routes.url_helpers.organization_agent_run_path(run.agent.organization, run.agent, run)
        }
      end

      def task_for_plan(plan, conversation)
        active = %w[planning executing].include?(plan.status)
        state = if !active
                  terminal_state(plan.status)
        elsif plan.status == "planning" && plan.mode == "manual_plan"
                  "waiting_for_user"
        else
                  "running"
        end
        {
          id: plan.id, kind: "plan", name: "#{plan.mode.humanize} task",
          conversation_id: conversation.id, conversation_title: conversation.title,
          agent_name: conversation.agent.name, state: state, progress: nil,
          started_at: plan.created_at.iso8601, terminal_status: active ? nil : state,
          request_id: nil, preview: nil,
          actions: active ? (state == "waiting_for_user" ? [ "stop", "approve_plan" ] : [ "stop" ]) : [],
          path: Rails.application.routes.url_helpers.resume_agent_run_path(plan)
        }
      end

      def pending_tasks(conversation)
        meta = conversation.metadata.is_a?(Hash) ? conversation.metadata : {}
        [ [ QUEUE_KEY, "Queued follow-up", "followup" ], [ STEERING_KEY, "Steering instruction", "steering" ] ]
          .flat_map do |key, name, kind|
            Array(meta[key]).select { |entry| entry.is_a?(Hash) }.map.with_index do |entry, index|
              {
                id: "#{kind}-#{index}-#{entry['client_request_id']}", kind: kind, name: name,
                conversation_id: conversation.id, conversation_title: conversation.title,
                agent_name: conversation.agent.name, state: "queued", progress: nil,
                started_at: entry["queued_at"], terminal_status: nil, request_id: entry["client_request_id"],
                preview: entry["content"].to_s.truncate(160), actions: [], path: nil
              }
            end
          end
      end

      def recent_tasks(conversation, active)
        active_ids = active.map { |task| [ task[:kind], task[:id] ] }
        runs = conversation.runs.where.not(status: %w[pending running]).order(created_at: :desc).limit(5).map { |run| task_for_run(run) }
        plans = conversation.agent_runs.where.not(status: %w[planning executing]).order(created_at: :desc).limit(5)
          .map { |plan| task_for_plan(plan, conversation) }
        (runs + plans).reject { |task| active_ids.include?([ task[:kind], task[:id] ]) }
          .sort_by { |task| task[:started_at].to_s }.reverse.take(8)
      end

      def terminal_state(status)
        { "succeeded" => "completed", "completed" => "completed", "interrupted" => "cancelled",
          "cancelled" => "cancelled", "failed" => "failed" }.fetch(status.to_s, status.to_s)
      end

      def admit(conversation, user, input, requested_mode)
        if input[:client_request_id].present?
          existing = existing_message(conversation, input[:client_request_id])
          return duplicate(existing, pending_count(conversation)) if existing

          pending = pending_entries(conversation).find do |entry|
            entry["client_request_id"].to_s == input[:client_request_id]
          end
          return duplicate_pending(input[:client_request_id], pending_count(conversation)) if pending
          return { status: :duplicate, message: nil, request_id: input[:client_request_id],
                   queued_count: pending_count(conversation) } if steering_consumed?(conversation, input[:client_request_id])
        end

        assets = readable_assets(user, input[:attachment_asset_ids])
        input[:attachment_asset_ids] = assets.map(&:id)
        candidate = build_message(conversation, input)
        return invalid(candidate.errors) unless candidate.valid?

        if (live = live_placeholder(conversation)) || active_record?(conversation)
          key = requested_mode.to_s == "steer" && assets.empty? ? STEERING_KEY : QUEUE_KEY
          meta = conversation.metadata.is_a?(Hash) ? conversation.metadata.dup : {}
          entries = Array(meta[key]).select { |entry| entry.is_a?(Hash) }
          if entries.size >= MAX_PENDING
            return invalid(ActiveModel::Errors.new(candidate).tap do |errors|
              errors.add(:base, "Too many waiting messages. Wait for the current turn to finish.")
            end)
          end

          meta[key] = entries + [ input.merge("queued_at" => Time.current.utc.iso8601) ]
          conversation.update_column(:metadata, meta)
          return { status: key == STEERING_KEY ? :steering : :queued,
                   request_id: input[:client_request_id].presence || live&.metadata&.dig("request_id"),
                   queued_count: pending_count(conversation) }
        end

        request_id = input[:client_request_id].presence || SecureRandom.uuid
        message = build_message(conversation, input)
        message.save!
        attach!(message, user, input)
        create_placeholder(conversation, request_id)
        enqueue(conversation: conversation, user: user, message: message, request_id: request_id)
        { status: :started, message: message, request_id: request_id, queued_count: pending_count(conversation) }
      end

      def dequeue(conversation, user)
        return nil if live_placeholder(conversation) || active_record?(conversation)

        meta = conversation.metadata.is_a?(Hash) ? conversation.metadata.dup : {}
        entries = Array(meta[QUEUE_KEY]).select { |entry| entry.is_a?(Hash) }
        input = entries.first&.deep_symbolize_keys
        return nil if input.nil?

        candidate = build_message(conversation, input)
        raise ActiveRecord::RecordInvalid, candidate unless candidate.valid?

        request_id = input[:client_request_id].to_s.presence || SecureRandom.uuid
        message = build_message(conversation, input)
        conversation.transaction do
          message.save!
          attach!(message, user, input)
          create_placeholder(conversation, request_id)
          conversation.update_column(:metadata, meta.except(QUEUE_KEY).merge(QUEUE_KEY => entries.drop(1)))
          enqueue(conversation: conversation, user: user, message: message, request_id: request_id)
        end
        { status: :started, message: message, request_id: request_id, queued_count: entries.size - 1 }
      end

      def build_message(conversation, input)
        metadata = {}
        metadata["client_request_id"] = input[:client_request_id] if input[:client_request_id].present?
        metadata["tools"] = input[:tools] if input[:tools].any?
        metadata["selected_model"] = input[:selected_model] if input[:selected_model].present?
        conversation.messages.build(role: "user", content: input[:content], metadata: metadata,
          pending_attachment_asset_ids: input[:attachment_asset_ids])
      end

      def attach!(message, user, input)
        message.attach_assets!(input[:attachment_asset_ids], for_user: user)
        AttachmentDraft.consume_attached_for(user, input[:attachment_draft_token], message.assets.ids)
      end

      def readable_assets(user, ids)
        return [] if ids.empty?

        Asset.where(id: ids).select { |asset| asset.readable_by?(user) }
      end

      def create_placeholder(conversation, request_id)
        conversation.messages.create!(role: "assistant", content: "", metadata: {
          "streaming" => true,
          "stream_started_at" => Time.current.utc.iso8601,
          "request_id" => request_id
        })
      end

      def enqueue(conversation:, user:, message:, request_id:)
        AgentStreamJob.perform_later(conversation_id: conversation.id, user_id: user.id,
          message_content: message.content, message_id: message.id, request_id: request_id)
      end

      def duplicate(message, queued_count)
        { status: :duplicate, message: message, request_id: message.metadata["client_request_id"], queued_count: queued_count }
      end

      def duplicate_pending(request_id, queued_count)
        { status: :duplicate_pending, request_id: request_id, queued_count: queued_count }
      end

      def invalid(errors)
        { status: :invalid, errors: errors.full_messages, queued_count: 0 }
      end

      def existing_message(conversation, request_id)
        conversation.messages.where(role: "user")
          .where("metadata->>'client_request_id' = ?", request_id)
          .order(created_at: :desc).first
      end

      def pending_entries(conversation)
        meta = conversation.metadata.is_a?(Hash) ? conversation.metadata : {}
        Array(meta[QUEUE_KEY]) + Array(meta[STEERING_KEY])
      end

      def pending_count(conversation)
        pending_entries(conversation).count { |entry| entry.is_a?(Hash) }
      end

      def defer_steering(conversation)
        conversation.with_lock do
          meta = conversation.metadata.is_a?(Hash) ? conversation.metadata.dup : {}
          steering = Array(meta[STEERING_KEY]).select { |entry| entry.is_a?(Hash) }
          return if steering.empty?

          queued = Array(meta[QUEUE_KEY]).select { |entry| entry.is_a?(Hash) }
          move_count = [ MAX_PENDING - queued.length, 0 ].max
          meta[QUEUE_KEY] = queued + steering.first(move_count)
          remaining = steering.drop(move_count)
          remaining.empty? ? meta.delete(STEERING_KEY) : meta[STEERING_KEY] = remaining
          conversation.update_column(:metadata, meta)
        end
      end

      def live?(message)
        started = message.stream_started_at
        started.present? && Time.current - started < CLAIM_TIMEOUT
      end

      def steering_consumed?(conversation, request_id)
        meta = conversation.metadata.is_a?(Hash) ? conversation.metadata : {}
        Array(meta[STEERING_IDS_KEY]).map(&:to_s).include?(request_id.to_s)
      end

      def merge_steering_receipts(meta, request_ids)
        receipts = Array(meta[STEERING_IDS_KEY]).map(&:to_s).reject(&:blank?)
        meta.merge(STEERING_IDS_KEY => (receipts + request_ids).uniq.last(MAX_STEERING_RECEIPTS))
      end

      def broadcast_tasks(conversation)
        ActionCable.server.broadcast("conversation:#{conversation.id}", {
          type: "background_tasks", conversation_id: conversation.id
        }.merge(task_summary(conversation)))
      end
    end
  end
end
