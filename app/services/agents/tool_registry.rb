require "json_schemer"

# Tool Registry - Manages available tools for agent function calling.
# Each tool has a name, description, JSON Schema parameters, and an executor.
module Agents
  class ToolRegistry
    class << self
      def register(name, description:, parameters:, &executor)
        tools[name] = {
          name: name,
          description: description,
          parameters: parameters,
          executor: executor,
          capability_key: nil
        }
      end

      # Capability-backed tool:_surfacing is gated on the capability state —
      # a disabled/unconfigured capability never surfaces to the model, and
      # execution is refused with a bounded result rather than a stub answer.
      def register_capability(name, capability, description:, parameters:, &executor)
        register(name, description: description, parameters: parameters, &executor)
        tools[name][:capability_key] = capability
      end

      def tools
        @tools ||= {}
      end

      def get(name)
        tools[name]
      end

      def capability_key_for(name)
        tool = get(name)
        tool && tool[:capability_key]
      end

      def all
        tools.values
      end

      def execute(name, arguments, context = {})
        tool = get(name)
        raise ArgumentError, "Unknown tool: #{name}" unless tool

        # Validate shape first (deterministic regardless of capability state),
        # then refuse execution when the backing capability is not enabled.
        validate_arguments!(tool[:parameters], arguments)

        capability = tool[:capability_key]
        if capability && !Capabilities::Registry.available?(capability)
          return { ok: false, error_code: "capability_unavailable", capability: capability.to_s }
        end

        # Execute the tool.
        tool[:executor].call(arguments, context)
      end

      def validate_arguments!(schema, arguments)
        schemer = JSONSchemer.schema(schema)
        errors = schemer.validate(arguments).to_a
        if errors.any?
          raise ArgumentError, "Invalid arguments: #{errors.map { |e| e['error'] }.join(', ')}"
        end
      end

      def schema_for(tool_name)
        tool = get(tool_name)
        return nil unless tool
        { name: tool[:name], description: tool[:description], parameters: tool[:parameters] }
      end

      def schemas(tool_names = nil)
        selected = tool_names ? all.select { |t| tool_names.include?(t[:name]) } : all
        selected.map { |t| schema_for(t[:name]) }.compact
      end
    end
  end
end

module Agents
  class ToolRegistry
    # Shared helpers for tool executors: resolve the acting user from the
    # executor context (runner now passes the full user object; older call
    # sites may pass only user_id) and shape bounded denial results.
    module ToolContext
      module_function

      def user_for(context)
        context[:user].is_a?(User) ? context[:user] : User.find_by(id: context[:user_id])
      end

      def unavailable(error_code, extra = {})
        { ok: false, error_code: error_code }.merge(extra)
      end
    end
  end
end

# Register built-in tools.
# Capability-backed: web_search. The tool only surfaces while the web_search
# capability is enabled (API key configured); unconfigured installs get a
# bounded refusal instead of a silent empty stub.
Agents::ToolRegistry.register_capability "web_search", "web_search",
  description: "Search the web for current information",
  parameters: {
    type: "object",
    properties: {
      query: { type: "string", description: "The search query" },
      num_results: { type: "integer", description: "Number of results to return (default: 5)" }
    },
    required: [ "query" ]
  } do |args, context|
  # In production, integrate with a search API (Google, Bing, Tavily, etc).
  { results: [], message: "Web search not yet configured" }
end

Agents::ToolRegistry.register "code_executor",
  description: "Execute Python or Ruby code (no network access) and return stdout/stderr. " \
               "Use for quick computations, JSON checks, or verifying the language runtime. " \
               "For anything involving files in the workspace prefer run_command instead.",
  parameters: {
    type: "object",
    properties: {
      code: { type: "string", description: "The source code to execute" },
      language: { type: "string", description: "python (default) or ruby" },
      workdir: { type: "string", description: "Optional absolute working directory for the process" }
    },
    required: [ "code" ]
  } do |args, _context|
  begin
    Agents::OsExecutor.run_code(args["code"], language: args["language"] || "python",
                                workdir: args["workdir"], timeout: args["workdir"] ? 30 : 30)
  rescue SecurityError => e
    { ok: false, error: e.message }
  end
end

Agents::ToolRegistry.register "run_command",
  description: "Run a bash shell command inside an approved workspace (home directory or /tmp). " \
               "Use for mkdir, ls, cp, mv, pip installs, running tests, git status, and verifying results. " \
               "Do not use for interactive or long-running services. Returns stdout, stderr, exit_code.",
  parameters: {
    type: "object",
    properties: {
      command: { type: "string", description: "The bash command line to execute" },
      workdir: { type: "string", description: "Optional absolute working directory (default: /Users" \
                                               " home or last used)" },
      timeout: { type: "integer", description: "Timeout in seconds, 1-120 (default 30)" }
    },
    required: [ "command" ]
  } do |args, _context|
  begin
    Agents::OsExecutor.run_command(args["command"], workdir: args["workdir"],
                                   timeout: args["timeout"] || Agents::OsExecutor::DEFAULT_TIMEOUT)
  rescue SecurityError => e
    { ok: false, error: e.message }
  end
end

Agents::ToolRegistry.register "memory_search",
  description: "Search the agent's memory for relevant information",
  parameters: {
    type: "object",
    properties: {
      query: { type: "string", description: "The search query" },
      limit: { type: "integer", description: "Maximum number of results (default: 5)" }
    },
    required: [ "query" ]
  } do |args, context|
  limit = args["limit"] || 5
  memories = Memory.search_by_text(args["query"],
    user_id: context[:user_id],
    agent_id: context[:agent_id],
    limit: limit
  )

  {
    memories: memories.map { |m| { content: m.content, source: m.source_type } }
  }
end

Agents::ToolRegistry.register "read_file",
  description: "Read the contents of a file (max 1MB). Paths must be absolute and inside the " \
               "approved workspace (/Users/... or /tmp/...). The Shams AI app's own code tree is blocked.",
  parameters: {
    type: "object",
    properties: {
      path: { type: "string", description: "Absolute file path to read" }
    },
    required: [ "path" ]
  } do |args, _context|
  Agents::OsExecutor.read_file(args["path"])
rescue SecurityError, StandardError => e
  { ok: false, error: e.message, path: args["path"] }
end

# Compatibility alias: agents may be configured with either name; both share
# the same executor and only the requested names surface via schemas().
Agents::ToolRegistry.register "file_reader",
  description: "Read the contents of a local workspace file (alias of read_file).",
  parameters: {
    type: "object",
    properties: {
      path: { type: "string", description: "Absolute file path to read" }
    },
    required: [ "path" ]
  } do |args, _context|
  Agents::OsExecutor.read_file(args["path"])
rescue SecurityError, StandardError => e
  { ok: false, error: e.message, path: args["path"] }
end

Agents::ToolRegistry.register "write_file",
  description: "Create or overwrite a file with the given content. Parent directories are created " \
               "automatically. Paths must be absolute and inside the approved workspace; the " \
               "Shams AI app's own code tree is blocked.",
  parameters: {
    type: "object",
    properties: {
      path: { type: "string", description: "Absolute path of the file to write" },
      content: { type: "string", description: "Full file content to write" }
    },
    required: [ "path", "content" ]
  } do |args, _context|
    path = args["path"]
    result = Agents::OsExecutor.write_file(path, args["content"])

    # Evidence: a write only succeeds if the bytes are verifiably on disk —
    # checked against the expanded absolute path the executor returns.
    verify_path = result.is_a?(Hash) ? (result[:path] || path) : path
    size = (File.size(verify_path) rescue 0)
    if !File.file?(verify_path) || size.zero?
      raise IOError, "write verification failed: file missing or empty after write"
    end

    base = result.is_a?(Hash) ? result : {}
    base.merge(ok: true, path: verify_path, bytes_written: size)
  rescue SecurityError, StandardError => e
    { ok: false, error: e.message, path: args["path"] }
  end

Agents::ToolRegistry.register "calculator",
  description: "Perform mathematical calculations",
  parameters: {
    type: "object",
    properties: {
      expression: { type: "string", description: "The mathematical expression to evaluate" }
    },
    required: [ "expression" ]
  } do |args, context|
  begin
    # Safe math: only allow numbers, basic operators, parens, decimals.
    sanitized = args["expression"].gsub(%r{[^0-9+\-*/().%\s]}, "")
    # Use a safer evaluation: parse into a simple AST and evaluate.
    result = SafeMath.eval(sanitized)
    { result: result, expression: args["expression"] }
  rescue => e
    { error: e.message }
  end
end

Agents::ToolRegistry.register "time",
  description: "Get the current date and time",
  parameters: {
    type: "object",
    properties: {
      timezone: { type: "string", description: "The timezone (e.g., 'America/New_York')" }
    }
  } do |args, context|
  tz = args["timezone"] || "UTC"
  { time: Time.now.in_time_zone(tz).to_s, timezone: tz }
end

# Capability-backed: file_extraction. Lets chat-mode agents read text the
# extraction pipeline pulled from files the user uploaded through THIS app
# (no local paths, no app internals) instead of claiming it cannot read files.
Agents::ToolRegistry.register_capability "read_asset", "file_extraction",
  description: "Read the extracted text of the USER'S UPLOADED file (uploads or library in this app). " \
               "Use when the user references a file they attached and you need its contents.",
  parameters: {
    type: "object",
    properties: {
      asset_id: { type: "string", description: "Asset id from list_assets or the user's reference" },
      max_chars: { type: "integer", description: "Optional content cap, 1000..20000 chars (default 20000)" }
    },
    required: [ "asset_id" ]
  } do |args, context|
  user = Agents::ToolRegistry::ToolContext.user_for(context)
  next Agents::ToolRegistry::ToolContext.unavailable("not_authorized") if user.nil?

  asset = Asset.find_by(id: args["asset_id"])
  next Agents::ToolRegistry::ToolContext.unavailable("asset_not_found", asset_id: args["asset_id"]) if asset.nil?
  next Agents::ToolRegistry::ToolContext.unavailable("not_authorized", asset_id: args["asset_id"]) unless asset.readable_by?(user)

  extraction = asset.extraction
  status = extraction&.status.to_s
  case status
  when "failed"
    { ok: false, asset_id: asset.id, asset: asset.filename, status: "failed",
      error_code: extraction.error_code, note: "Extraction failed; report this honestly to the user." }
  when "pending", "processing"
    { ok: true, asset_id: asset.id, asset: asset.filename, status: status,
      content: nil, note: "Extraction still in progress." }
  when "completed"
    max_chars = args["max_chars"].to_i
    max_chars = 20_000 if max_chars <= 0 || max_chars > 20_000
    max_chars = [ max_chars, 1000 ].max
    text = extraction.content.to_s
    truncated = text.length > max_chars
    {
      ok: true, asset_id: asset.id, asset: asset.filename,
      category: asset.metadata["category"], status: "completed",
      content: text.first(max_chars), truncated: truncated, total_chars: text.length
    }
  else
    { ok: false, asset_id: asset.id, asset: asset.filename, status: status.presence || "missing",
      error_code: "no_extraction", note: "No extracted text is available for this asset." }
  end
end

# Capability-backed: library. Inventory of the user's uploaded assets so the
# model can discover what exists before reading.
Agents::ToolRegistry.register_capability "list_assets", "library",
  description: "List the user's recently uploaded files in this app " \
               "(uploads/library with ids, filenames, categories, extraction states).",
  parameters: {
    type: "object",
    properties: {
      limit: { type: "integer", description: "Maximum assets to list, 1..25 (default 10)" }
    }
  } do |args, context|
  user = Agents::ToolRegistry::ToolContext.user_for(context)
  next Agents::ToolRegistry::ToolContext.unavailable("not_authorized") if user.nil?

  limit = args["limit"].to_i
  limit = 10 if limit <= 0
  limit = [ limit, 25 ].min

  assets = user.assets.order(created_at: :desc).limit(limit).includes(:extraction)
  {
    ok: true,
    assets: assets.map do |asset|
      {
        id: asset.id,
        filename: asset.filename,
        category: asset.metadata["category"],
        byte_size: asset.byte_size,
        extraction_status: asset.extraction&.status
      }
    end
  }
end

# Capability-backed: image_generation (Phase 3). Queues an async provider call;
# the finished image is broadcast into the conversation and lands in /images.
# One generation in flight per conversation — a second call is refused honestly
# instead of double-billing while the first image is still rendering.
Agents::ToolRegistry.register_capability "generate_image", "image_generation",
  description: "Generate a new image from a text prompt. The image appears in this conversation " \
               "and in the user's image gallery when ready. Returns a job id immediately — never " \
               "invent or claim an image url yourself.",
  parameters: {
    type: "object",
    properties: {
      prompt: { type: "string", description: "Detailed description of the image to generate" },
      size: { type: "string", description: "1024x1024 (default, square), 1024x1536 (portrait), 1536x1024 (landscape)" },
      quality: { type: "string", description: "auto (default), low, medium or high" }
    },
    required: [ "prompt" ]
  } do |args, context|
  user = Agents::ToolRegistry::ToolContext.user_for(context)
  next Agents::ToolRegistry::ToolContext.unavailable("not_authorized") if user.nil?

  conversation_id = context[:conversation_id]
  if ImageGeneration.in_flight_for_conversation?(conversation_id)
    next { ok: false, error_code: "generation_in_flight",
           note: "An image is already generating in this conversation. Ask the user to wait for it." }
  end

  generation = ImageGeneration.new(
    user: user,
    organization_id: Agent.find_by(id: context[:agent_id])&.organization_id,
    prompt: args["prompt"].to_s.strip,
    size: ImageGeneration::SIZES.include?(args["size"]) ? args["size"] : "1024x1024",
    quality: ImageGeneration::QUALITIES.include?(args["quality"]) ? args["quality"] : "auto"
  )
  unless generation.save
    next { ok: false, error_code: "invalid_request", errors: generation.errors.full_messages }
  end

  generation.merge_metadata!("conversation_id" => conversation_id) if conversation_id.present?
  Images::GenerateJob.perform_later(generation.id)

  { ok: true, image_generation_id: generation.id, status: "queued",
    note: "The image will appear in the conversation and the gallery when ready." }
end
