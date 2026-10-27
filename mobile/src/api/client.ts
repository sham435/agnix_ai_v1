import { API_BASE } from '../config';
import type { Agent, Conversation, ConversationDetail, Message, Run } from './types';

interface CsrfResponse {
  token: string;
}

class ShamsApi {
  baseUrl: string;
  private csrfToken: string | null = null;

  constructor(baseUrl: string = API_BASE) {
    this.baseUrl = baseUrl.replace(/\/$/, '');
  }

  private async request<T>(path: string, options: RequestInit = {}): Promise<T> {
    const headers: Record<string, string> = {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      ...(options.headers as Record<string, string> | undefined),
    };

    if (this.csrfToken) {
      headers['X-CSRF-Token'] = this.csrfToken;
    }

    const response = await fetch(`${this.baseUrl}${path}`, {
      ...options,
      headers,
      credentials: 'include',
    });

    this.captureCsrfToken(response);

    if (!response.ok) {
      let message = `Request failed with status ${response.status}`;
      try {
        const body = await response.json();
        if (body && typeof body === 'object' && 'error' in body) {
          message = String(body.error);
        }
      } catch {
        // ignore non-JSON error bodies
      }
      throw new Error(message);
    }

    if (response.status === 204) {
      return undefined as T;
    }

    return (await response.json()) as T;
  }

  private captureCsrfToken(response: Response): void {
    const header = response.headers.get('x-csrf-token');
    if (header) {
      this.csrfToken = header;
    }
  }

  async fetchCsrfToken(): Promise<void> {
    try {
      const data = await this.request<CsrfResponse>('/api/v1/csrf');
      this.csrfToken = data.token;
    } catch {
      // token stays null; POSTs will fail until a token is present
    }
  }

  async login(email: string, password: string): Promise<void> {
    await this.request<{ user: unknown }>('/api/v1/sessions', {
      method: 'POST',
      body: JSON.stringify({ email, password }),
    });
  }

  logout(): Promise<void> {
    return this.request<void>('/api/v1/sessions', { method: 'DELETE' });
  }

  listAgents(): Promise<Agent[]> {
    return this.request<Agent[]>('/api/v1/agents');
  }

  getAgent(id: number): Promise<Agent> {
    return this.request<Agent>(`/api/v1/agents/${id}`);
  }

  listConversations(): Promise<Conversation[]> {
    return this.request<Conversation[]>('/api/v1/conversations');
  }

  getConversation(id: number): Promise<ConversationDetail> {
    return this.request<ConversationDetail>(`/api/v1/conversations/${id}`);
  }

  createMessage(conversationId: number, content: string): Promise<{ message: Message; status: string }> {
    return this.request<{ message: Message; status: string }>(
      `/api/v1/conversations/${conversationId}/messages`,
      {
        method: 'POST',
        body: JSON.stringify({ content }),
      }
    );
  }

  getRun(id: number): Promise<Run> {
    return this.request<Run>(`/api/v1/runs/${id}`);
  }
}

export const api = new ShamsApi();