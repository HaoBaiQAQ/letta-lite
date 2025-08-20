import ffi from 'ffi-napi';
import ref from 'ref-napi';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// FFI types
const voidPtr = ref.refType(ref.types.void);
const stringPtr = ref.refType(ref.types.CString);

// Load the native library
const libPath = process.platform === 'darwin'
  ? path.join(__dirname, '../../..', 'target/release/libletta_ffi.dylib')
  : process.platform === 'win32'
  ? path.join(__dirname, '../../..', 'target/release/letta_ffi.dll')
  : path.join(__dirname, '../../..', 'target/release/libletta_ffi.so');

const native = ffi.Library(libPath, {
  'letta_init_storage': ['int', ['string']],
  'letta_create_agent': [voidPtr, ['string']],
  'letta_free_agent': ['void', [voidPtr]],
  'letta_load_af': ['int', [voidPtr, 'string']],
  'letta_export_af': [stringPtr, [voidPtr]],
  'letta_set_block': ['int', [voidPtr, 'string', 'string']],
  'letta_get_block': [stringPtr, [voidPtr, 'string']],
  'letta_append_archival': ['int', [voidPtr, 'string', 'string']],
  'letta_search_archival': [stringPtr, [voidPtr, 'string', 'int']],
  'letta_converse': [stringPtr, [voidPtr, 'string']],
  'letta_configure_sync': ['int', ['string']],
  'letta_sync_with_cloud': ['int', [voidPtr]],
  'letta_free_str': ['void', [stringPtr]],
});

// Helper to read and free C strings
function readCString(ptr: any): string | null {
  if (ptr.isNull()) return null;
  const str = ptr.readCString();
  native.letta_free_str(ptr);
  return str;
}

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
  toolTrace?: any[];
  usage?: {
    promptTokens: number;
    completionTokens: number;
    totalTokens: number;
  };
  error?: string;
}

export interface ArchivalResult {
  folder: string;
  text: string;
  metadata?: Record<string, any>;
}

export interface AgentFile {
  version: string;
  agents: any[];
  blocks: any[];
  metadata: any;
}

export interface SyncConfig {
  endpoint?: string;
  apiKey: string;
  syncInterval?: number;
  conflictResolution?: string;
  autoSync?: boolean;
}

export class LettaAgent {
  private handle: any;

  constructor(handle: any) {
    this.handle = handle;
  }

  async setBlock(label: string, value: string): Promise<void> {
    const result = native.letta_set_block(this.handle, label, value);
    if (result !== 0) {
      throw new Error('Failed to set block');
    }
  }

  async getBlock(label: string): Promise<string | null> {
    const ptr = native.letta_get_block(this.handle, label);
    return readCString(ptr);
  }

  async appendArchival(folder: string, text: string): Promise<void> {
    const result = native.letta_append_archival(this.handle, folder, text);
    if (result !== 0) {
      throw new Error('Failed to append archival');
    }
  }

  async searchArchival(query: string, topK: number = 5): Promise<ArchivalResult[]> {
    const ptr = native.letta_search_archival(this.handle, query, topK);
    const json = readCString(ptr);
    if (!json) return [];
    return JSON.parse(json);
  }

  async converse(message: string): Promise<ConversationResponse> {
    const msgJson = JSON.stringify({ text: message });
    const ptr = native.letta_converse(this.handle, msgJson);
    const json = readCString(ptr);
    if (!json) throw new Error('Conversation failed');
    return JSON.parse(json);
  }

  async exportAF(): Promise<AgentFile> {
    const ptr = native.letta_export_af(this.handle);
    const json = readCString(ptr);
    if (!json) throw new Error('Export failed');
    return JSON.parse(json);
  }

  async importAF(af: AgentFile): Promise<void> {
    const json = JSON.stringify(af);
    const result = native.letta_load_af(this.handle, json);
    if (result !== 0) {
      throw new Error('Import failed');
    }
  }

  async syncWithCloud(): Promise<void> {
    const result = native.letta_sync_with_cloud(this.handle);
    if (result !== 0) {
      throw new Error('Sync failed');
    }
  }

  async destroy(): Promise<void> {
    if (this.handle && !this.handle.isNull()) {
      native.letta_free_agent(this.handle);
      this.handle = null;
    }
  }
}

export class LettaLite {
  static async initialize(storagePath?: string): Promise<void> {
    const result = native.letta_init_storage(storagePath || '');
    if (result !== 0) {
      throw new Error('Failed to initialize storage');
    }
  }

  static async createAgent(config: AgentConfig = {}): Promise<LettaAgent> {
    const fullConfig = {
      name: config.name || 'assistant',
      system_prompt: config.systemPrompt || 'You are a helpful AI assistant.',
      model: config.model || 'toy',
      max_messages: config.maxMessages || 100,
      max_context_tokens: config.maxContextTokens || 8192,
      temperature: config.temperature || 0.7,
      tools_enabled: config.toolsEnabled !== false,
    };

    const configJson = JSON.stringify(fullConfig);
    const handle = native.letta_create_agent(configJson);
    
    if (handle.isNull()) {
      throw new Error('Failed to create agent');
    }

    return new LettaAgent(handle);
  }

  static async configureSync(config: SyncConfig): Promise<void> {
    const fullConfig = {
      endpoint: config.endpoint || 'https://api.letta.ai',
      api_key: config.apiKey,
      sync_interval: config.syncInterval || 300000,
      conflict_resolution: config.conflictResolution || 'last-write-wins',
      auto_sync: config.autoSync || false,
    };

    const configJson = JSON.stringify(fullConfig);
    const result = native.letta_configure_sync(configJson);
    
    if (result !== 0) {
      throw new Error('Failed to configure sync');
    }
  }
}