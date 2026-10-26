# frozen_string_literal: true

# Plugin catalog (Phase 4 — Plugins Manager).
#
# A frozen marketplace definition of the integrations this install can offer
# as agent tools. Every entry maps 1:1 to a provider already persisted by
# `ToolIntegration` (plus the generic `webhook` receiver), and every declared
# tool is backed by a REAL executor class under `app/services/integrations/`
# — the catalog never advertises a tool it cannot execute. `google` ships
# with no tools on purpose: Gmail sends need an OAuth token this app does
# not persist (see OauthCallbacksController), so declaring one would be a
# fake tool.
#
# Tool names are namespaced "<provider>.<tool>" (e.g. "slack.post_message")
# so they can never collide with the native Agents::ToolRegistry names.
module Tools
  class Catalog
    PLUGINS = [
      {
        key: "stripe",
        name: "Stripe",
        description: "Payments and billing: look up recent charges and hand customers a checkout link.",
        category: "Payments",
        icon: "card",
        docs_url: "https://docs.stripe.com/api",
        credential_fields: [
          { key: "api_key", label: "Secret key", type: "password", required: true, hint: "sk_live_… or sk_test_…" },
          { key: "webhook_secret", label: "Webhook signing secret", type: "password", required: false, hint: "whsec_… (only needed for webhooks)" }
        ],
        tools: [
          {
            name: "list_recent_payments",
            summary: "Show the most recent payments with amount, currency and status.",
            description: "List the most recent Stripe payments (charges) for this account, newest first, " \
                         "with amount, currency, status and created date. Use when the user asks about " \
                         "incoming payments or recent transactions.",
            parameters: {
              type: "object",
              properties: {
                limit: { type: "integer", description: "Number of payments to return, 1..50 (default 10)" }
              }
            },
            executor: "Integrations::Stripe::ListRecentPayments"
          },
          {
            name: "create_payment_link",
            summary: "Create a hosted Stripe Checkout link for a one-off payment.",
            description: "Create a Stripe Checkout payment link for a one-off charge and return its URL so " \
                         "the user can send it to a customer. Amounts are in the smallest currency unit " \
                         "(cents for USD).",
            parameters: {
              type: "object",
              properties: {
                amount_cents: { type: "integer", description: "Charge amount in the smallest currency unit (e.g. 2500 = $25.00)" },
                currency: { type: "string", description: "Three-letter ISO currency code, lowercase (default usd)" },
                description: { type: "string", description: "Line item name shown to the customer on the checkout page" },
                success_url: { type: "string", description: "Absolute URL the customer returns to after paying" }
              },
              required: [ "amount_cents", "description", "success_url" ]
            },
            executor: "Integrations::Stripe::CreatePaymentLink"
          }
        ],
        capabilities: []
      },
      {
        key: "slack",
        name: "Slack",
        description: "Post messages into your team's Slack channels from any agent run.",
        category: "Communication",
        icon: "chat",
        docs_url: "https://api.slack.com/methods/chat.postMessage",
        credential_fields: [
          { key: "api_key", label: "Bot token", type: "password", required: true, hint: "xoxb-… from a Slack app with chat:write" }
        ],
        tools: [
          {
            name: "post_message",
            summary: "Send a message to a Slack channel.",
            description: "Post a text message to a Slack channel (e.g. '#general' or a channel id) using the " \
                         "connected workspace's bot token. Use when the user asks to notify or report into Slack.",
            parameters: {
              type: "object",
              properties: {
                channel: { type: "string", description: "Channel name (#general) or channel id" },
                text: { type: "string", description: "Message text (Slack mrkdwn supported)" }
              },
              required: [ "channel", "text" ]
            },
            executor: "Integrations::Slack::PostMessage"
          }
        ],
        capabilities: []
      },
      {
        key: "resend",
        name: "Resend",
        description: "Transactional email through the Resend API.",
        category: "Email",
        icon: "mail",
        docs_url: "https://resend.com/docs",
        credential_fields: [
          { key: "api_key", label: "API key", type: "password", required: true, hint: "re_…" },
          { key: "from_address", label: "Default from address", type: "text", required: false, hint: "updates@yourdomain.com (a verified sender)" }
        ],
        tools: [
          {
            name: "send_email",
            summary: "Send a plain-text email through Resend.",
            description: "Send one transactional email via the connected Resend account. Returns the provider " \
                         "message id. Use when the user asks to email someone and Resend is connected.",
            parameters: {
              type: "object",
              properties: {
                to: { type: "string", description: "Recipient email address" },
                subject: { type: "string", description: "Email subject" },
                body: { type: "string", description: "Plain-text email body" },
                from: { type: "string", description: "Sender address (defaults to the integration's configured sender)" }
              },
              required: [ "to", "subject", "body" ]
            },
            executor: "Integrations::Resend::SendEmail"
          }
        ],
        capabilities: []
      },
      {
        key: "postmark",
        name: "Postmark",
        description: "Transactional email through the Postmark API.",
        category: "Email",
        icon: "mail",
        docs_url: "https://postmarkapp.com/developer/api/email-api",
        credential_fields: [
          { key: "api_key", label: "Server token", type: "password", required: true, hint: "Postmark server API token" },
          { key: "from_address", label: "Default from address", type: "text", required: false, hint: "Approved sender for this server" }
        ],
        tools: [
          {
            name: "send_email",
            summary: "Send a plain-text email through Postmark.",
            description: "Send one email via the connected Postmark server. Returns the provider message id. " \
                         "Use when the user asks to email someone and Postmark is the connected email plugin.",
            parameters: {
              type: "object",
              properties: {
                to: { type: "string", description: "Recipient email address" },
                subject: { type: "string", description: "Email subject" },
                body: { type: "string", description: "Plain-text email body" },
                from: { type: "string", description: "Sender address (defaults to the integration's configured sender)" }
              },
              required: [ "to", "subject", "body" ]
            },
            executor: "Integrations::Postmark::SendEmail"
          }
        ],
        capabilities: []
      },
      {
        key: "github",
        name: "GitHub",
        description: "File and browse issues in your repositories with a personal access token.",
        category: "Developer tools",
        icon: "code",
        docs_url: "https://docs.github.com/en/rest/issues/issues",
        credential_fields: [
          { key: "api_key", label: "Personal access token", type: "password", required: true, hint: "classic or fine-grained PAT with repo scope" }
        ],
        tools: [
          {
            name: "create_issue",
            summary: "Open a new issue in a repository.",
            description: "Create a GitHub issue in the given 'owner/repo' repository using the connected " \
                         "account's token. Returns the issue number and html_url.",
            parameters: {
              type: "object",
              properties: {
                owner: { type: "string", description: "Repository owner (user or organization login)" },
                repo: { type: "string", description: "Repository name" },
                title: { type: "string", description: "Issue title" },
                body: { type: "string", description: "Issue body (Markdown)" },
                labels: { type: "array", items: { type: "string" }, description: "Optional label names" }
              },
              required: [ "owner", "repo", "title" ]
            },
            executor: "Integrations::Github::CreateIssue"
          },
          {
            name: "list_issues",
            summary: "List issues in a repository.",
            description: "List issues for a GitHub repository ('owner/repo'), newest first, filtered by " \
                         "state. Returns number, title, state and html_url for each.",
            parameters: {
              type: "object",
              properties: {
                owner: { type: "string", description: "Repository owner (user or organization login)" },
                repo: { type: "string", description: "Repository name" },
                state: { type: "string", description: "open (default), closed or all" },
                limit: { type: "integer", description: "Maximum issues to return, 1..100 (default 20)" }
              },
              required: [ "owner", "repo" ]
            },
            executor: "Integrations::Github::ListIssues"
          }
        ],
        capabilities: [ "github" ]
      },
      {
        key: "whatsapp",
        name: "WhatsApp",
        description: "Send WhatsApp text messages through the Meta Cloud API.",
        category: "Communication",
        icon: "phone",
        docs_url: "https://developers.facebook.com/docs/whatsapp/cloud-api",
        credential_fields: [
          { key: "api_key", label: "Permanently-granted access token", type: "password", required: true, hint: "Cloud API bearer token" }
        ],
        config_fields: [
          { key: "phone_number_id", label: "Phone number ID", type: "text", required: true, hint: "WABA phone number id from the Meta app dashboard" }
        ],
        tools: [
          {
            name: "send_message",
            summary: "Send a plain-text WhatsApp message to a number.",
            description: "Send a WhatsApp text message to an E.164 phone number (digits only, with country " \
                         "code) via the connected Cloud API number. Returns the provider message id.",
            parameters: {
              type: "object",
              properties: {
                to: { type: "string", description: "Recipient phone number in international format without '+' (e.g. 14155552671)" },
                text: { type: "string", description: "Message text" }
              },
              required: [ "to", "text" ]
            },
            executor: "Integrations::Whatsapp::SendMessage"
          }
        ],
        capabilities: []
      },
      {
        key: "notion",
        name: "Notion",
        description: "Search pages and databases your Notion integration can see.",
        category: "Knowledge",
        icon: "book",
        docs_url: "https://developers.notion.com/reference/post-search",
        credential_fields: [
          { key: "api_key", label: "Internal integration secret", type: "password", required: true, hint: "secret_… (start page/database shared with the integration)" }
        ],
        tools: [
          {
            name: "search",
            summary: "Search shared Notion pages and databases.",
            description: "Search the Notion workspace for pages and databases shared with the connected " \
                         "integration. Returns id, object type and a plain title for each hit.",
            parameters: {
              type: "object",
              properties: {
                query: { type: "string", description: "Search text (empty lists everything the integration can access)" },
                limit: { type: "integer", description: "Maximum results to return, 1..50 (default 10)" }
              }
            },
            executor: "Integrations::Notion::Search"
          }
        ],
        capabilities: [ "notion" ]
      },
      {
        key: "webhook",
        name: "Custom Webhook",
        description: "Call any external HTTP endpoint with a JSON payload.",
        category: "Automation",
        icon: "bolt",
        docs_url: "https://en.wikipedia.org/wiki/Webhook",
        credential_fields: [],
        config_fields: [
          { key: "webhook_url", label: "Endpoint URL", type: "text", required: true, hint: "https://example.com/hooks/agent" }
        ],
        tools: [
          {
            name: "post_json",
            summary: "POST a JSON payload to the configured endpoint.",
            description: "Send an HTTP POST with a JSON body to the webhook endpoint configured for this " \
                         "connection and return the response status. Use for custom integrations, ping URLs " \
                         "and outbound automation triggers.",
            parameters: {
              type: "object",
              properties: {
                payload: { type: "object", description: "JSON object to POST to the endpoint" },
                event: { type: "string", description: "Optional short event label added to the payload as 'event'" }
              },
              required: [ "payload" ]
            },
            executor: "Integrations::Webhook::PostJson"
          }
        ],
        capabilities: []
      },
      {
        key: "google",
        name: "Google",
        description: "Google workspace connection settings. Agent tools for Gmail require OAuth token " \
                     "storage this app does not have yet, so no tools are offered today.",
        category: "Productivity",
        icon: "cloud",
        docs_url: "https://developers.google.com/identity/protocols/oauth2",
        credential_fields: [
          { key: "api_key", label: "API key", type: "password", required: false, hint: "Cloud project API key (no agent tools yet)" }
        ],
        # Honest by design: Gmail send needs an OAuth access/refresh token pair, and this app's
        # OmniAuth callbacks never persist tokens — only user identity. Declaring send_gmail here
        # would advertise a tool no executor can honor, so google ships zero catalog tools.
        tools: [],
        capabilities: []
      }
    ].freeze

    class << self
      def all
        PLUGINS
      end

      def keys
        PLUGINS.map { |plugin| plugin[:key] }
      end

      def find(key)
        return nil if key.nil?

        PLUGINS.find { |plugin| plugin[:key] == key.to_s }
      end

      def tool(plugin_key, tool_name)
        plugin = find(plugin_key)
        return nil unless plugin

        plugin[:tools].find { |t| t[:name] == tool_name.to_s }
      end

      def namespaced(plugin_key, tool_name)
        "#{plugin_key}.#{tool_name}"
      end

      # Resolve a "<provider>.<tool>" name to its tool hash (with :plugin_key
      # merged in), or nil when the catalog does not know it.
      def tool_by_namespaced_name(name)
        return nil unless name.is_a?(String) && name.include?(".")

        plugin_key, tool_name = name.split(".", 2)
        tool = tool(plugin_key, tool_name)
        tool&.merge(plugin_key: plugin_key, plugin_name: find(plugin_key)[:name])
      end

      # True for names the catalog owns (dotted + known). Unknown dotted
      # names are NOT catalog tools — the runner must refuse them.
      def catalog_tool?(name)
        !tool_by_namespaced_name(name).nil?
      end

      def provider_for(name)
        tool_by_namespaced_name(name)&.dig(:plugin_key)
      end

      # OpenAI-style schemas for every tool of one plugin.
      def tool_schemas_for(key)
        plugin = find(key)
        return [] unless plugin

        plugin[:tools].map { |t| schema_for(plugin[:key], t) }
      end

      # Schemas for a list of namespaced names (unknown names drop out).
      def schemas(names)
        Array(names).filter_map do |name|
          tool = tool_by_namespaced_name(name)
          schema_for(tool[:plugin_key], tool) if tool
        end
      end

      def all_tool_names
        PLUGINS.flat_map { |plugin| plugin[:tools].map { |t| namespaced(plugin[:key], t[:name]) } }
      end

      # Plugin rows backed by a connected + active ToolIntegration of the org.
      def available_plugins(organization)
        return [] unless organization

        organization.tool_integrations.active.filter_map do |integration|
          plugin = find(integration.provider)
          next nil unless plugin && plugin[:tools].any?

          { plugin: plugin, integration: integration }
        end
      end

      # Namespaced names the org can actually run right now (connected +
      # active integrations only). Used by the runner's surfacing gate and
      # by the agent-form picker.
      def available_tool_names(organization)
        available_plugins(organization).flat_map do |row|
          row[:plugin][:tools].map { |t| namespaced(row[:plugin][:key], t[:name]) }
        end
      end

      def connected?(organization, key)
        return false unless organization

        organization.tool_integrations.where(provider: key.to_s).exists?
      end

      private

      def schema_for(plugin_key, tool)
        {
          name: namespaced(plugin_key, tool[:name]),
          description: tool[:description],
          parameters: tool[:parameters]
        }
      end
    end
  end
end
