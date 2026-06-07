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
          executor: executor
        }
      end

      def tools
        @tools ||= {}
      end

      def get(name)
        tools[name]
      end

      def all
        tools.values
      end

      def execute(name, arguments, context = {})
        tool = get(name)
        raise ArgumentError, "Unknown tool: #{name}" unless tool

        # Validate arguments against JSON Schema.
        validate_arguments!(tool[:parameters], arguments)

        # Execute the tool.
        tool[:executor].call(arguments, context)
      end

      def validate_arguments!(schema, arguments)
        require "json_schemer"
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

# Register built-in tools.
Agents::ToolRegistry.register "web_search",
  description: "Search the web for current information",
  parameters: {
    type: "object",
    properties: {
      query: { type: "string", description: "The search query" },
      num_results: { type: "integer", description: "Number of results to return (default: 5)" }
    },
    required: ["query"]
  } do |args, context|
  # In production, integrate with a search API (Google, Bing, Tavily, etc).
  { results: [], message: "Web search not yet configured" }
end

Agents::ToolRegistry.register "code_executor",
  description: "Execute Ruby code and return the result",
  parameters: {
    type: "object",
    properties: {
      code: { type: "string", description: "The Ruby code to execute" },
      language: { type: "string", description: "Programming language (default: ruby)" }
    },
    required: ["code"]
  } do |args, context|
  # WARNING: In production, sandbox this heavily.
  { result: "Code execution requires sandbox configuration", output: "" }
end

Agents::ToolRegistry.register "memory_search",
  description: "Search the agent's memory for relevant information",
  parameters: {
    type: "object",
    properties: {
      query: { type: "string", description: "The search query" },
      limit: { type: "integer", description: "Maximum number of results (default: 5)" }
    },
    required: ["query"]
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

Agents::ToolRegistry.register "file_reader",
  description: "Read the contents of a file",
  parameters: {
    type: "object",
    properties: {
      path: { type: "string", description: "The file path to read" }
    },
    required: ["path"]
  } do |args, context|
  { content: "File reading requires configured file system access", path: args["path"] }
end

Agents::ToolRegistry.register "calculator",
  description: "Perform mathematical calculations",
  parameters: {
    type: "object",
    properties: {
      expression: { type: "string", description: "The mathematical expression to evaluate" }
    },
    required: ["expression"]
  } do |args, context|
  begin
    # Safe math evaluation.
    result = eval(args["expression"].gsub(%r{[^0-9+\-*/().%\s]}, ""))
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
