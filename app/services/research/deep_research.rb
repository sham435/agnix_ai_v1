# frozen_string_literal: true

require "digest"
require "timeout"
require "uri"

module Research
  # Findings are search excerpts, not claims of full-page review or LLM synthesis.
  class DeepResearch
    MAX_SOURCES = 10
    MAX_CALLS = 20
    MAX_SECONDS = 120
    MAX_QUESTIONS = 5
    MAX_SNIPPET = 2000
    TOOL_RESULT_MAX_BYTES = 3500
    TOOL_SNIPPET_LIMITS = [ 300, 180, 100, 50, 0 ].freeze

    class << self
      def call(topic:, user:, organization:, questions: [], cancelled: -> { false })
        new(topic: topic, user: user, organization: organization, questions: questions, cancelled: cancelled).send(:perform)
      end

      def canonical_url(value)
        return unless value.is_a?(String) && value.length <= 2048
        return if value.match?(/[\x00-\x1f\x7f\\]/)

        uri = URI.parse(value)
        return unless %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil?

        uri = uri.normalize
        uri.fragment = nil
        uri.path = "/" if uri.path.empty?
        uri.to_s
      rescue URI::InvalidURIError, ArgumentError
        nil
      end

      def source_id(url)
        "src_#{Digest::SHA256.hexdigest(url.to_s)[0, 12]}"
      end

      def tool_result(result)
        ledger = Array(result[:sources]).first(MAX_SOURCES).filter_map do |source|
          next unless source.is_a?(Hash)

          url = canonical_url(source[:url])
          next unless url

          { source_id: source_id(url), title: source[:title].to_s.first(120), url: url,
            snippet: source[:snippet].to_s.first(MAX_SNIPPET) }
        end.uniq { |source| source[:url] }
        findings = Array(result[:findings]).filter_map do |finding|
          next unless finding.is_a?(Hash)

          url = canonical_url(finding[:source_url])
          next unless url

          { source_id: source_id(url), basis: finding[:basis].to_s.first(80).presence || "search_snippet" }
        end.uniq { |finding| finding[:source_id] }
        selected = fit_tool_sources(ledger, result, findings)
        originals = ledger.index_by { |source| source[:source_id] }
        payload = nil
        while selected.any?
          shortened = selected.count do |source|
            source[:snippet].to_s.length < originals.fetch(source[:source_id])[:snippet].to_s.length
          end
          payload = tool_payload(result, selected, findings,
            omitted_sources: ledger.length - selected.length, shortened_sources: shortened)
          break if payload.to_json.bytesize <= TOOL_RESULT_MAX_BYTES

          selected.pop
        end
        payload || tool_payload(result, [], findings, omitted_sources: ledger.length, shortened_sources: 0)
      end

      private

      def fit_tool_sources(ledger, result, findings)
        selected = []
        ledger.each do |source|
          fitted = nil
          TOOL_SNIPPET_LIMITS.each do |limit|
            trial = source.merge(snippet: source[:snippet].to_s[0, limit])
            payload = tool_payload(result, selected + [ trial ], findings,
              omitted_sources: ledger.length - selected.length - 1, shortened_sources: 0)
            next unless payload.to_json.bytesize <= TOOL_RESULT_MAX_BYTES

            fitted = trial
            break
          end
          break unless fitted

          selected << fitted
        end
        selected
      end

      def tool_payload(result, sources, findings, omitted_sources:, shortened_sources:)
        included = sources.map { |source| source[:source_id] }
        {
          ok: %w[completed partial].include?(result[:status].to_s),
          status: result[:status],
          reason: result[:reason],
          calls: Array(result[:calls]).length,
          sources: sources.each_with_index.map { |source, index| source.merge(number: index + 1) },
          findings: findings.select { |finding| included.include?(finding[:source_id]) }
            .map { |finding| finding.slice(:source_id, :basis) },
          omitted_sources: omitted_sources,
          shortened_sources: shortened_sources,
          limits: result[:limits],
          elapsed_seconds: result[:elapsed_seconds],
          caveat: result[:caveat]
        }
      end
    end

    private

    def initialize(topic:, user:, organization:, questions:, cancelled:)
      @topic = topic
      @user = user
      @organization = organization
      @questions = questions
      @cancelled = cancelled
      @sources = []
      @calls = []
      @seen = {}
    end

    def perform
      @started = now
      return finish("error", "invalid_request") unless valid_input?
      return finish("cancelled", "cancelled") if @cancelled.call

      authorized = ToolIntegration.authorized_organization_for(@user, organization: @organization)
      return finish("error", "not_authorized") unless @organization && authorized&.id == @organization.id

      return finish("error", "integration_inactive") if ToolIntegration.connection_disabled?(authorized, "web_search")

      @integration = ToolIntegration.connection_for(authorized, "web_search")
      if @integration && @integration.organization_id != authorized.id
        return finish("error", "not_authorized")
      end
      @api_key = @integration&.api_key.presence || server_key
      return finish("error", "missing_credentials") if @api_key.blank?

      queries.each do |query|
        reason = stop_reason
        return finish(reason == "cancelled" ? "cancelled" : "partial", reason) if reason

        response = search(query)
        return finish("partial", "time_limit") if remaining <= 0
        unless response[:ok]
          return finish(@sources.empty? ? "error" : "partial", response[:error_code] || "provider_error")
        end

        collect(response[:sources], query)
        return finish("cancelled", "cancelled") if @cancelled.call
      end
      finish("completed", nil)
    rescue Timeout::Error
      finish("partial", "time_limit")
    rescue StandardError
      finish(@sources.empty? ? "error" : "partial", "provider_error")
    end

    def valid_input?
      @topic.is_a?(String) && @topic.strip.present? && @topic.length <= 400 &&
        @questions.is_a?(Array) && @questions.length <= MAX_QUESTIONS &&
        @questions.all? { |question| question.is_a?(String) && question.strip.present? && question.length <= 512 } &&
        @cancelled.respond_to?(:call)
    end

    def queries
      ([ @topic.strip ] + @questions.map(&:strip) + [ "#{@topic.strip} evidence", "#{@topic.strip} limitations" ]).uniq
    end

    def server_key
      ENV["SHAMS_WEB_SEARCH_API_KEY"].presence || Rails.application.credentials.dig(:web_search, :api_key)
    end

    def stop_reason
      return "cancelled" if @cancelled.call
      return "time_limit" if remaining <= 0
      return "source_limit" if @sources.length >= MAX_SOURCES
      return "call_limit" if @calls.length >= MAX_CALLS

      nil
    end

    def search(query)
      call = { query: query, status: "error" }
      @calls << call
      response = Integrations::WebSearch.call(
        arguments: { "query" => query, "num_results" => [ 3, MAX_SOURCES - @sources.length ].min },
        integration: @integration, api_key: @api_key, timeout: remaining,
        context: { user: @user, organization: @organization }
      )
      call[:status] = response[:ok] ? "completed" : "error"
      response
    end

    def collect(sources, query)
      Array(sources).first(MAX_SOURCES).each do |source|
        break if @sources.length >= MAX_SOURCES
        next unless source.is_a?(Hash)

        url = self.class.canonical_url(source[:url])
        next if url.nil? || @seen[url]

        @seen[url] = true
        @sources << { source_id: self.class.source_id(url), title: source[:title].to_s.first(300), url: url,
                      snippet: source[:snippet].to_s.first(MAX_SNIPPET), query: query }
      end
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def remaining
      MAX_SECONDS - (now - @started)
    end

    def finish(status, reason)
      { status: status, reason: reason, calls: @calls, sources: @sources,
        findings: @sources.map { |source| { text: source[:snippet], source_url: source[:url], basis: "search_snippet" } },
        limits: { sources: MAX_SOURCES, calls: MAX_CALLS, seconds: MAX_SECONDS, questions: MAX_QUESTIONS,
                  snippet_characters: MAX_SNIPPET },
        elapsed_seconds: (now - @started).round(3),
        caveat: "Findings are provider search snippets; full pages have not been reviewed." }
    end
  end
end
