package ai.letta.lite

import com.google.gson.Gson
import com.google.gson.annotations.SerializedName
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.Closeable

/**
 * Main LettaLite Android/Kotlin interface
 */
class LettaLite(config: AgentConfig = AgentConfig()) : Closeable {
    private val handle: Long
    private val gson = Gson()
    
    init {
        System.loadLibrary("letta_ffi")
        
        val configJson = gson.toJson(config)
        handle = nativeCreateAgent(configJson)
        if (handle == 0L) {
            throw LettaException("Failed to create agent")
        }
    }
    
    companion object {
        /**
         * Initialize LettaLite storage
         */
        @JvmStatic
        fun initialize(storagePath: String? = null) {
            val result = nativeInitStorage(storagePath ?: "")
            if (result != 0) {
                throw LettaException("Failed to initialize storage")
            }
        }
        
        /**
         * Configure cloud sync
         */
        @JvmStatic
        fun configureSync(config: SyncConfig) {
            val configJson = Gson().toJson(config)
            val result = nativeConfigureSync(configJson)
            if (result != 0) {
                throw LettaException("Failed to configure sync")
            }
        }
    }
    
    /**
     * Set a memory block value
     */
    fun setBlock(label: String, value: String) {
        val result = nativeSetBlock(handle, label, value)
        if (result != 0) {
            throw LettaException("Failed to set memory block")
        }
    }
    
    /**
     * Get a memory block value
     */
    fun getBlock(label: String): String? {
        return nativeGetBlock(handle, label)
    }
    
    /**
     * Add text to archival memory
     */
    fun appendArchival(folder: String = "default", text: String) {
        val result = nativeAppendArchival(handle, folder, text)
        if (result != 0) {
            throw LettaException("Failed to append to archival")
        }
    }
    
    /**
     * Search archival memory
     */
    fun searchArchival(query: String, topK: Int = 5): List<ArchivalResult> {
        val json = nativeSearchArchival(handle, query, topK)
            ?: throw LettaException("Search failed")
        
        return gson.fromJson(json, Array<ArchivalResult>::class.java).toList()
    }
    
    /**
     * Converse with the agent
     */
    suspend fun converse(message: String): ConversationResponse = withContext(Dispatchers.IO) {
        val messageObj = mapOf("text" to message)
        val messageJson = gson.toJson(messageObj)
        
        val responseJson = nativeConverse(handle, messageJson)
            ?: throw LettaException("Conversation failed")
        
        gson.fromJson(responseJson, ConversationResponse::class.java)
    }
    
    /**
     * Export agent to AF format
     */
    fun exportAF(): AgentFile {
        val json = nativeExportAF(handle)
            ?: throw LettaException("Export failed")
        
        return gson.fromJson(json, AgentFile::class.java)
    }
    
    /**
     * Import agent from AF format
     */
    fun importAF(agentFile: AgentFile) {
        val json = gson.toJson(agentFile)
        val result = nativeLoadAF(handle, json)
        if (result != 0) {
            throw LettaException("Import failed")
        }
    }
    
    /**
     * Sync with cloud
     */
    suspend fun syncWithCloud() = withContext(Dispatchers.IO) {
        val result = nativeSyncWithCloud(handle)
        if (result != 0) {
            throw LettaException("Sync failed")
        }
    }
    
    override fun close() {
        if (handle != 0L) {
            nativeFreeAgent(handle)
        }
    }
    
    // Native methods
    internal external fun nativeInitStorage(path: String): Int  // 已改：private → internal
    private external fun nativeCreateAgent(configJson: String): Long
    private external fun nativeFreeAgent(handle: Long)
    private external fun nativeLoadAF(handle: Long, json: String): Int
    private external fun nativeExportAF(handle: Long): String?
    private external fun nativeSetBlock(handle: Long, label: String, value: String): Int
    private external fun nativeGetBlock(handle: Long, label: String): String?
    private external fun nativeAppendArchival(handle: Long, folder: String, text: String): Int
    private external fun nativeSearchArchival(handle: Long, query: String, topK: Int): String?
    private external fun nativeConverse(handle: Long, messageJson: String): String?
    internal external fun nativeConfigureSync(configJson: String): Int  // 已改：private → internal
    private external fun nativeSyncWithCloud(handle: Long): Int
}

// Data classes

data class AgentConfig(
    val name: String = "assistant",
    @SerializedName("system_prompt")
    val systemPrompt: String = "You are a helpful AI assistant.",
    val model: String = "toy",
    @SerializedName("max_messages")
    val maxMessages: Int = 100,
    @SerializedName("max_context_tokens")
    val maxContextTokens: Int = 8192,
    val temperature: Float = 0.7f,
    @SerializedName("tools_enabled")
    val toolsEnabled: Boolean = true
)

data class ConversationResponse(
    val text: String,
    @SerializedName("tool_trace")
    val toolTrace: List<Map<String, Any>>?,
    val usage: TokenUsage?,
    val error: String?
)

data class TokenUsage(
    @SerializedName("prompt_tokens")
    val promptTokens: Int,
    @SerializedName("completion_tokens")
    val completionTokens: Int,
    @SerializedName("total_tokens")
    val totalTokens: Int
)

data class ArchivalResult(
    val folder: String,
    val text: String,
    val metadata: Map<String, Any>?
)

data class AgentFile(
    val version: String,
    val agents: List<AgentExport>,
    val blocks: List<BlockExport>,
    val metadata: AgentFileMetadata
)

data class AgentExport(
    val id: String,
    val name: String,
    @SerializedName("system_prompt")
    val systemPrompt: String,
    val messages: List<Message>
)

data class BlockExport(
    val id: String,
    val label: String,
    val value: String,
    val limit: Int
)

data class Message(
    val role: String,
    val content: String,
    val timestamp: String
)

data class AgentFileMetadata(
    @SerializedName("letta_version")
    val lettaVersion: String,
    @SerializedName("export_time")
    val exportTime: String,
    @SerializedName("export_source")
    val exportSource: String
)

data class SyncConfig(
    val endpoint: String = "https://api.letta.ai",
    @SerializedName("api_key")
    val apiKey: String,
    @SerializedName("sync_interval")
    val syncInterval: Int = 300000,
    @SerializedName("conflict_resolution")
    val conflictResolution: String = "last-write-wins",
    @SerializedName("auto_sync")
    val autoSync: Boolean = false
)

class LettaException(message: String) : Exception(message)
