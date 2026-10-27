export interface Agent {
  id: number;
  name: string;
  slug: string | null;
  description: string | null;
  system_prompt: string | null;
  model: string;
  provider: string;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export interface Conversation {
  id: number;
  user_id: number;
  agent_id: number;
  status: string;
  title: string | null;
  created_at: string;
  updated_at: string;
  agent?: Agent;
}

export interface Message {
  id: number;
  conversation_id: number;
  role: string;
  content: string;
  agent_id: number | null;
  run_id: number | null;
  created_at: string;
  agent?: Agent;
}

export interface ConversationDetail extends Conversation {
  messages: Message[];
}

export interface Run {
  id: number;
  agent_id: number;
  conversation_id: number | null;
  status: string;
  input: Record<string, unknown> | null;
  output: Record<string, unknown> | null;
  error_message: string | null;
  tokens_used: number | null;
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
  updated_at: string;
}