import Foundation

/// Main LettaLite Swift interface
public final class LettaLite {
    private let handle: OpaquePointer
    
    /// Initialize LettaLite with optional storage path
    public static func initialize(storagePath: String? = nil) throws {
        let path = storagePath ?? ""
        let result = letta_init_storage(path)
        if result != 0 {
            throw LettaError.initializationFailed
        }
    }
    
    /// Create a new agent with configuration
    public init(config: AgentConfig = AgentConfig()) throws {
        let configData = try JSONEncoder().encode(config)
        let configString = String(data: configData, encoding: .utf8)!
        
        guard let ptr = letta_create_agent(configString) else {
            throw LettaError.agentCreationFailed
        }
        
        self.handle = ptr
    }
    
    deinit {
        letta_free_agent(handle)
    }
    
    /// Set a memory block value
    public func setBlock(_ label: String, value: String) throws {
        let result = letta_set_block(handle, label, value)
        if result != 0 {
            throw LettaError.memoryOperationFailed
        }
    }
    
    /// Get a memory block value
    public func getBlock(_ label: String) -> String? {
        guard let cStr = letta_get_block(handle, label) else {
            return nil
        }
        defer { letta_free_str(cStr) }
        return String(cString: cStr)
    }
    
    /// Add text to archival memory
    public func appendArchival(folder: String = "default", text: String) throws {
        let result = letta_append_archival(handle, folder, text)
        if result != 0 {
            throw LettaError.archivalOperationFailed
        }
    }
    
    /// Search archival memory
    public func searchArchival(query: String, topK: Int = 5) throws -> [ArchivalResult] {
        guard let cStr = letta_search_archival(handle, query, Int32(topK)) else {
            throw LettaError.searchFailed
        }
        defer { letta_free_str(cStr) }
        
        let jsonString = String(cString: cStr)
        let data = jsonString.data(using: .utf8)!
        return try JSONDecoder().decode([ArchivalResult].self, from: data)
    }
    
    /// Converse with the agent
    public func converse(_ message: String) async throws -> ConversationResponse {
        let messageObj = ["text": message]
        let messageData = try JSONSerialization.data(withJSONObject: messageObj)
        let messageString = String(data: messageData, encoding: .utf8)!
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                guard let cStr = letta_converse(self.handle, messageString) else {
                    continuation.resume(throwing: LettaError.conversationFailed)
                    return
                }
                defer { letta_free_str(cStr) }
                
                let responseString = String(cString: cStr)
                let data = responseString.data(using: .utf8)!
                
                do {
                    let response = try JSONDecoder().decode(ConversationResponse.self, from: data)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Export agent to AF format
    public func exportAF() throws -> AgentFile {
        guard let cStr = letta_export_af(handle) else {
            throw LettaError.exportFailed
        }
        defer { letta_free_str(cStr) }
        
        let jsonString = String(cString: cStr)
        let data = jsonString.data(using: .utf8)!
        return try JSONDecoder().decode(AgentFile.self, from: data)
    }
    
    /// Import agent from AF format
    public func importAF(_ agentFile: AgentFile) throws {
        let data = try JSONEncoder().encode(agentFile)
        let jsonString = String(data: data, encoding: .utf8)!
        
        let result = letta_load_af(handle, jsonString)
        if result != 0 {
            throw LettaError.importFailed
        }
    }
    
    /// Configure cloud sync
    public static func configureSync(config: SyncConfig) throws {
        let data = try JSONEncoder().encode(config)
        let jsonString = String(data: data, encoding: .utf8)!
        
        let result = letta_configure_sync(jsonString)
        if result != 0 {
            throw LettaError.syncConfigurationFailed
        }
    }
    
    /// Sync with cloud
    public func syncWithCloud() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let result = letta_sync_with_cloud(self.handle)
                if result != 0 {
                    continuation.resume(throwing: LettaError.syncFailed)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - Models

public struct AgentConfig: Codable {
    public var name: String
    public var systemPrompt: String
    public var model: String
    public var maxMessages: Int
    public var maxContextTokens: Int
    public var temperature: Float
    public var toolsEnabled: Bool
    
    public init(
        name: String = "assistant",
        systemPrompt: String = "You are a helpful AI assistant.",
        model: String = "toy",
        maxMessages: Int = 100,
        maxContextTokens: Int = 8192,
        temperature: Float = 0.7,
        toolsEnabled: Bool = true
    ) {
        self.name = name
        self.systemPrompt = systemPrompt
        self.model = model
        self.maxMessages = maxMessages
        self.maxContextTokens = maxContextTokens
        self.temperature = temperature
        self.toolsEnabled = toolsEnabled
    }
    
    enum CodingKeys: String, CodingKey {
        case name
        case systemPrompt = "system_prompt"
        case model
        case maxMessages = "max_messages"
        case maxContextTokens = "max_context_tokens"
        case temperature
        case toolsEnabled = "tools_enabled"
    }
}

public struct ConversationResponse: Codable {
    public let text: String
    public let toolTrace: [[String: Any]]?
    public let usage: TokenUsage?
    public let error: String?
    
    enum CodingKeys: String, CodingKey {
        case text
        case toolTrace = "tool_trace"
        case usage
        case error
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        usage = try container.decodeIfPresent(TokenUsage.self, forKey: .usage)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        
        // Handle tool trace as array of dictionaries
        if let traceData = try container.decodeIfPresent(Data.self, forKey: .toolTrace) {
            toolTrace = try JSONSerialization.jsonObject(with: traceData) as? [[String: Any]]
        } else {
            toolTrace = nil
        }
    }
}

public struct TokenUsage: Codable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
    
    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

public struct ArchivalResult: Codable {
    public let folder: String
    public let text: String
    public let metadata: [String: Any]?
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folder = try container.decode(String.self, forKey: .folder)
        text = try container.decode(String.self, forKey: .text)
        
        if let metaData = try container.decodeIfPresent(Data.self, forKey: .metadata) {
            metadata = try JSONSerialization.jsonObject(with: metaData) as? [String: Any]
        } else {
            metadata = nil
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case folder, text, metadata
    }
}

public struct AgentFile: Codable {
    public let version: String
    public let agents: [AgentExport]
    public let blocks: [BlockExport]
    public let metadata: AgentFileMetadata
}

public struct AgentExport: Codable {
    public let id: String
    public let name: String
    public let systemPrompt: String
    public let messages: [Message]
    
    enum CodingKeys: String, CodingKey {
        case id, name
        case systemPrompt = "system_prompt"
        case messages
    }
}

public struct BlockExport: Codable {
    public let id: String
    public let label: String
    public let value: String
    public let limit: Int
}

public struct Message: Codable {
    public let role: String
    public let content: String
    public let timestamp: String
}

public struct AgentFileMetadata: Codable {
    public let lettaVersion: String
    public let exportTime: String
    public let exportSource: String
    
    enum CodingKeys: String, CodingKey {
        case lettaVersion = "letta_version"
        case exportTime = "export_time"
        case exportSource = "export_source"
    }
}

public struct SyncConfig: Codable {
    public let endpoint: String
    public let apiKey: String
    public let syncInterval: Int
    public let conflictResolution: String
    public let autoSync: Bool
    
    public init(
        endpoint: String = "https://api.letta.ai",
        apiKey: String,
        syncInterval: Int = 300000,
        conflictResolution: String = "last-write-wins",
        autoSync: Bool = false
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.syncInterval = syncInterval
        self.conflictResolution = conflictResolution
        self.autoSync = autoSync
    }
    
    enum CodingKeys: String, CodingKey {
        case endpoint
        case apiKey = "api_key"
        case syncInterval = "sync_interval"
        case conflictResolution = "conflict_resolution"
        case autoSync = "auto_sync"
    }
}

// MARK: - Errors

public enum LettaError: LocalizedError {
    case initializationFailed
    case agentCreationFailed
    case memoryOperationFailed
    case archivalOperationFailed
    case searchFailed
    case conversationFailed
    case exportFailed
    case importFailed
    case syncConfigurationFailed
    case syncFailed
    
    public var errorDescription: String? {
        switch self {
        case .initializationFailed:
            return "Failed to initialize LettaLite storage"
        case .agentCreationFailed:
            return "Failed to create agent"
        case .memoryOperationFailed:
            return "Memory operation failed"
        case .archivalOperationFailed:
            return "Archival operation failed"
        case .searchFailed:
            return "Search operation failed"
        case .conversationFailed:
            return "Conversation failed"
        case .exportFailed:
            return "Failed to export agent"
        case .importFailed:
            return "Failed to import agent"
        case .syncConfigurationFailed:
            return "Failed to configure sync"
        case .syncFailed:
            return "Sync operation failed"
        }
    }
}

// MARK: - C FFI Declarations

@_silgen_name("letta_init_storage")
func letta_init_storage(_ path: UnsafePointer<CChar>) -> Int32

@_silgen_name("letta_create_agent")
func letta_create_agent(_ config: UnsafePointer<CChar>) -> OpaquePointer?

@_silgen_name("letta_free_agent")
func letta_free_agent(_ handle: OpaquePointer)

@_silgen_name("letta_load_af")
func letta_load_af(_ handle: OpaquePointer, _ json: UnsafePointer<CChar>) -> Int32

@_silgen_name("letta_export_af")
func letta_export_af(_ handle: OpaquePointer) -> UnsafeMutablePointer<CChar>?

@_silgen_name("letta_set_block")
func letta_set_block(_ handle: OpaquePointer, _ label: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) -> Int32

@_silgen_name("letta_get_block")
func letta_get_block(_ handle: OpaquePointer, _ label: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("letta_append_archival")
func letta_append_archival(_ handle: OpaquePointer, _ folder: UnsafePointer<CChar>, _ text: UnsafePointer<CChar>) -> Int32

@_silgen_name("letta_search_archival")
func letta_search_archival(_ handle: OpaquePointer, _ query: UnsafePointer<CChar>, _ topK: Int32) -> UnsafeMutablePointer<CChar>?

@_silgen_name("letta_converse")
func letta_converse(_ handle: OpaquePointer, _ message: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("letta_configure_sync")
func letta_configure_sync(_ config: UnsafePointer<CChar>) -> Int32

@_silgen_name("letta_sync_with_cloud")
func letta_sync_with_cloud(_ handle: OpaquePointer) -> Int32

@_silgen_name("letta_free_str")
func letta_free_str(_ str: UnsafeMutablePointer<CChar>)