import { NativeModules, Platform } from 'react-native';

const LINKING_ERROR =
  `The package 'letta-lite' doesn't seem to be linked. Make sure: \n\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go\n';

const LettaLiteNative = NativeModules.LettaLite
  ? NativeModules.LettaLite
  : new Proxy(
      {},
      {
        get() {
          throw new Error(LINKING_ERROR);
        },
      }
    );

export interface AgentConfig {
  name?: string;
  systemPrompt?: string;
  model?: string;
  maxMessages?: number;
  maxContextTokens?: number;
  temperature?: number;
  toolsEnabled?: boolean;
}

export interface ConversationResponse {
  text: string;
  toolTrace?: Array<Record<string, any>>;
  usage?: TokenUsage;
  error?: string;
}

export interface TokenUsage {
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
}

export interface ArchivalResult {
  folder: string;
  text: string;
  metadata?: Record<string, any>;
}

export interface AgentFile {
  version: string;
  agents: AgentExport[];
  blocks: BlockExport[];
  metadata: AgentFileMetadata;
}

export interface AgentExport {
  id: string;
  name: string;
  systemPrompt: string;
  messages: Message[];
}

export interface BlockExport {
  id: string;
  label: string;
  value: string;
  limit: number;
}

export interface Message {
  role: string;
  content: string;
  timestamp: string;
}

export interface AgentFileMetadata {
  lettaVersion: string;
  exportTime: string;
  exportSource: string;
}

export interface SyncConfig {
  endpoint?: string;
  apiKey: string;
  syncInterval?: number;
  conflictResolution?: string;
  autoSync?: boolean;
}

class LettaLiteAgent {
  private agentId: string;

  constructor(agentId: string) {
    this.agentId = agentId;
  }

  /**
   * Set a memory block value
   */
  async setBlock(label: string, value: string): Promise<void> {
    return LettaLiteNative.setBlock(this.agentId, label, value);
  }

  /**
   * Get a memory block value
   */
  async getBlock(label: string): Promise<string | null> {
    return LettaLiteNative.getBlock(this.agentId, label);
  }

  /**
   * Add text to archival memory
   */
  async appendArchival(folder: string, text: string): Promise<void> {
    return LettaLiteNative.appendArchival(this.agentId, folder, text);
  }

  /**
   * Search archival memory
   */
  async searchArchival(query: string, topK: number = 5): Promise<ArchivalResult[]> {
    const json = await LettaLiteNative.searchArchival(this.agentId, query, topK);
    return JSON.parse(json);
  }

  /**
   * Converse with the agent
   */
  async converse(message: string): Promise<ConversationResponse> {
    const json = await LettaLiteNative.converse(this.agentId, JSON.stringify({ text: message }));
    return JSON.parse(json);
  }

  /**
   * Export agent to AF format
   */
  async exportAF(): Promise<AgentFile> {
    const json = await LettaLiteNative.exportAF(this.agentId);
    return JSON.parse(json);
  }

  /**
   * Import agent from AF format
   */
  async importAF(agentFile: AgentFile): Promise<void> {
    return LettaLiteNative.importAF(this.agentId, JSON.stringify(agentFile));
  }

  /**
   * Sync with cloud
   */
  async syncWithCloud(): Promise<void> {
    return LettaLiteNative.syncWithCloud(this.agentId);
  }

  /**
   * Destroy the agent and free resources
   */
  async destroy(): Promise<void> {
    return LettaLiteNative.destroyAgent(this.agentId);
  }
}

export class LettaLite {
  private static agents = new Map<string, LettaLiteAgent>();

  /**
   * Initialize LettaLite storage
   */
  static async initialize(storagePath?: string): Promise<void> {
    return LettaLiteNative.initialize(storagePath || '');
  }

  /**
   * Create a new agent
   */
  static async createAgent(config: AgentConfig = {}): Promise<LettaLiteAgent> {
    const defaultConfig: AgentConfig = {
      name: 'assistant',
      systemPrompt: 'You are a helpful AI assistant.',
      model: 'toy',
      maxMessages: 100,
      maxContextTokens: 8192,
      temperature: 0.7,
      toolsEnabled: true,
    };

    const finalConfig = { ...defaultConfig, ...config };
    const agentId = await LettaLiteNative.createAgent(JSON.stringify({
      name: finalConfig.name,
      system_prompt: finalConfig.systemPrompt,
      model: finalConfig.model,
      max_messages: finalConfig.maxMessages,
      max_context_tokens: finalConfig.maxContextTokens,
      temperature: finalConfig.temperature,
      tools_enabled: finalConfig.toolsEnabled,
    }));

    const agent = new LettaLiteAgent(agentId);
    this.agents.set(agentId, agent);
    return agent;
  }

  /**
   * Configure cloud sync
   */
  static async configureSync(config: SyncConfig): Promise<void> {
    const defaultConfig = {
      endpoint: 'https://api.letta.ai',
      syncInterval: 300000,
      conflictResolution: 'last-write-wins',
      autoSync: false,
    };

    const finalConfig = { ...defaultConfig, ...config };
    return LettaLiteNative.configureSync(JSON.stringify({
      endpoint: finalConfig.endpoint,
      api_key: finalConfig.apiKey,
      sync_interval: finalConfig.syncInterval,
      conflict_resolution: finalConfig.conflictResolution,
      auto_sync: finalConfig.autoSync,
    }));
  }

  /**
   * Get all active agents
   */
  static getAgents(): LettaLiteAgent[] {
    return Array.from(this.agents.values());
  }

  /**
   * Destroy all agents and clean up
   */
  static async cleanup(): Promise<void> {
    for (const agent of this.agents.values()) {
      await agent.destroy();
    }
    this.agents.clear();
  }
}

export default LettaLite;