use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;
use std::sync::Mutex;
use lazy_static::lazy_static;
use serde_json::json;

use letta_core::{
    Agent, AgentConfig, AgentState,
    provider::{ProviderFactory, ProviderConfig, ToyConfig},
    tool::ToolSchema,
    af::AgentFile,
};
use letta_storage::{Storage, StorageConfig};
use letta_sync::{SyncClient, SyncConfig};

// Global runtime for async operations
lazy_static! {
    static ref RUNTIME: tokio::runtime::Runtime = tokio::runtime::Runtime::new().unwrap();
    static ref AGENTS: Mutex<Vec<Option<Box<Agent>>>> = Mutex::new(Vec::new());
    static ref STORAGE: Mutex<Option<Storage>> = Mutex::new(None);
    static ref SYNC_CLIENT: Mutex<Option<SyncClient>> = Mutex::new(None);
}

/// Agent handle for FFI
#[repr(C)]
pub struct AgentHandle {
    index: usize,
}

/// Convert C string to Rust String
unsafe fn c_str_to_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        String::new()
    } else {
        CStr::from_ptr(ptr).to_string_lossy().into_owned()
    }
}

/// Convert Rust String to C string
fn string_to_c_str(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(c_str) => c_str.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Initialize the storage system
#[no_mangle]
pub extern "C" fn letta_init_storage(path: *const c_char) -> i32 {
    let path_str = unsafe { c_str_to_string(path) };
    
    let config = if path_str.is_empty() {
        StorageConfig::default()
    } else {
        StorageConfig {
            path: path_str.into(),
            max_connections: 5,
        }
    };
    
    match Storage::new(config) {
        Ok(storage) => {
            *STORAGE.lock().unwrap() = Some(storage);
            0
        }
        Err(_) => -1,
    }
}

/// Create a new agent
#[no_mangle]
pub extern "C" fn letta_create_agent(config_json: *const c_char) -> *mut AgentHandle {
    let config_str = unsafe { c_str_to_string(config_json) };
    
    let config_result: Result<serde_json::Value, _> = serde_json::from_str(&config_str);
    if config_result.is_err() {
        return ptr::null_mut();
    }
    
    let config_value = config_result.unwrap();
    
    // Parse agent configuration
    let agent_config = AgentConfig {
        name: config_value.get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("assistant")
            .to_string(),
        system_prompt: config_value.get("system_prompt")
            .and_then(|v| v.as_str())
            .unwrap_or("You are a helpful AI assistant.")
            .to_string(),
        model: config_value.get("model")
            .and_then(|v| v.as_str())
            .unwrap_or("toy")
            .to_string(),
        max_messages: config_value.get("max_messages")
            .and_then(|v| v.as_u64())
            .unwrap_or(100) as usize,
        max_context_tokens: config_value.get("max_context_tokens")
            .and_then(|v| v.as_u64())
            .unwrap_or(8192) as usize,
        temperature: config_value.get("temperature")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.7) as f32,
        tools_enabled: config_value.get("tools_enabled")
            .and_then(|v| v.as_bool())
            .unwrap_or(true),
    };
    
    // Create provider based on model
    let provider_config = if agent_config.model == "toy" {
        ProviderConfig::Toy(ToyConfig { deterministic: true })
    } else {
        // Default to toy for now
        ProviderConfig::Toy(ToyConfig { deterministic: false })
    };
    
    // Create provider
    let provider = RUNTIME.block_on(async {
        ProviderFactory::create(provider_config).await
    });
    
    if provider.is_err() {
        return ptr::null_mut();
    }
    
    // Create agent
    let agent = Agent::new(agent_config, provider.unwrap());
    
    // Store agent
    let mut agents = AGENTS.lock().unwrap();
    let index = agents.len();
    agents.push(Some(Box::new(agent)));
    
    Box::into_raw(Box::new(AgentHandle { index }))
}

/// Free an agent
#[no_mangle]
pub extern "C" fn letta_free_agent(handle: *mut AgentHandle) {
    if handle.is_null() {
        return;
    }
    
    unsafe {
        let handle = Box::from_raw(handle);
        let mut agents = AGENTS.lock().unwrap();
        if handle.index < agents.len() {
            agents[handle.index] = None;
        }
    }
}

/// Load agent from AF file
#[no_mangle]
pub extern "C" fn letta_load_af(handle: *mut AgentHandle, af_json: *const c_char) -> i32 {
    if handle.is_null() {
        return -1;
    }
    
    let af_str = unsafe { c_str_to_string(af_json) };
    
    unsafe {
        let handle = &*handle;
        let mut agents = AGENTS.lock().unwrap();
        
        if handle.index >= agents.len() || agents[handle.index].is_none() {
            return -1;
        }
        
        // Parse AF
        let af_result = AgentFile::from_json(&af_str);
        if af_result.is_err() {
            return -1;
        }
        
        // Import state
        let import_result = AgentFile::import(&af_result.unwrap());
        if import_result.is_err() {
            return -1;
        }
        
        let (_config, state) = import_result.unwrap();
        
        // Update agent state
        if let Some(agent) = &mut agents[handle.index] {
            if agent.import_state(&serde_json::to_string(&state).unwrap()).is_err() {
                return -1;
            }
        }
    }
    
    0
}

/// Export agent to AF format
#[no_mangle]
pub extern "C" fn letta_export_af(handle: *mut AgentHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    
    unsafe {
        let handle = &*handle;
        let agents = AGENTS.lock().unwrap();
        
        if handle.index >= agents.len() || agents[handle.index].is_none() {
            return ptr::null_mut();
        }
        
        if let Some(agent) = &agents[handle.index] {
            // Get tool schemas
            let tool_schemas: Vec<ToolSchema> = vec![]; // TODO: Get from agent
            
            // Export to AF
            let af_result = AgentFile::export(&agent.config, &agent.state, tool_schemas);
            if af_result.is_err() {
                return ptr::null_mut();
            }
            
            // Convert to JSON
            let json_result = AgentFile::to_json(&af_result.unwrap());
            if json_result.is_err() {
                return ptr::null_mut();
            }
            
            return string_to_c_str(json_result.unwrap());
        }
    }
    
    ptr::null_mut()
}

/// Set a memory block
#[no_mangle]
pub extern "C" fn letta_set_block(handle: *mut AgentHandle, label: *const c_char, value: *const c_char) -> i32 {
    if handle.is_null() {
        return -1;
    }
    
    let label_str = unsafe { c_str_to_string(label) };
    let value_str = unsafe { c_str_to_string(value) };
    
    unsafe {
        let handle = &*handle;
        let mut agents = AGENTS.lock().unwrap();
        
        if handle.index >= agents.len() || agents[handle.index].is_none() {
            return -1;
        }
        
        if let Some(agent) = &mut agents[handle.index] {
            if agent.set_memory_block(&label_str, &value_str).is_err() {
                return -1;
            }
        }
    }
    
    0
}

/// Get a memory block
#[no_mangle]
pub extern "C" fn letta_get_block(handle: *mut AgentHandle, label: *const c_char) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    
    let label_str = unsafe { c_str_to_string(label) };
    
    unsafe {
        let handle = &*handle;
        let agents = AGENTS.lock().unwrap();
        
        if handle.index >= agents.len() || agents[handle.index].is_none() {
            return ptr::null_mut();
        }
        
        if let Some(agent) = &agents[handle.index] {
            if let Some(value) = agent.get_memory_block(&label_str) {
                return string_to_c_str(value);
            }
        }
    }
    
    ptr::null_mut()
}

/// Add to archival memory
#[no_mangle]
pub extern "C" fn letta_append_archival(handle: *mut AgentHandle, folder: *const c_char, text: *const c_char) -> i32 {
    if handle.is_null() {
        return -1;
    }
    
    let folder_str = unsafe { c_str_to_string(folder) };
    let text_str = unsafe { c_str_to_string(text) };
    
    unsafe {
        let handle = &*handle;
        let mut agents = AGENTS.lock().unwrap();
        
        if handle.index >= agents.len() || agents[handle.index].is_none() {
            return -1;
        }
        
        if let Some(agent) = &mut agents[handle.index] {
            agent.add_archival(&folder_str, &text_str);
        }
    }
    
    0
}

/// Search archival memory
#[no_mangle]
pub extern "C" fn letta_search_archival(handle: *mut AgentHandle, query: *const c_char, top_k: i32) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    
    let query_str = unsafe { c_str_to_string(query) };
    
    unsafe {
        let handle = &*handle;
        let agents = AGENTS.lock().unwrap();
        
        if handle.index >= agents.len() || agents[handle.index].is_none() {
            return ptr::null_mut();
        }
        
        if let Some(agent) = &agents[handle.index] {
            let results = agent.search_archival(&query_str, top_k as usize);
            let json = serde_json::to_string(&results).unwrap_or_default();
            return string_to_c_str(json);
        }
    }
    
    ptr::null_mut()
}

/// Converse with the agent
#[no_mangle]
pub extern "C" fn letta_converse(handle: *mut AgentHandle, user_msg_json: *const c_char) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    
    let msg_str = unsafe { c_str_to_string(user_msg_json) };
    
    // Parse message
    let msg_result: Result<serde_json::Value, _> = serde_json::from_str(&msg_str);
    if msg_result.is_err() {
        return string_to_c_str(json!({
            "error": "Invalid message JSON"
        }).to_string());
    }
    
    let msg_value = msg_result.unwrap();
    let text = msg_value.get("text")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    
    unsafe {
        let handle = &*handle;
        let mut agents = AGENTS.lock().unwrap();
        
        if handle.index >= agents.len() || agents[handle.index].is_none() {
            return string_to_c_str(json!({
                "error": "Invalid agent handle"
            }).to_string());
        }
        
        if let Some(agent) = &mut agents[handle.index] {
            // Run step in runtime
            let result = RUNTIME.block_on(async {
                agent.step(text).await
            });
            
            match result {
                Ok(step_result) => {
                    let response = json!({
                        "text": step_result.text,
                        "tool_trace": step_result.tool_trace,
                        "usage": step_result.usage,
                    });
                    return string_to_c_str(response.to_string());
                }
                Err(e) => {
                    let error = json!({
                        "error": e.to_string()
                    });
                    return string_to_c_str(error.to_string());
                }
            }
        }
    }
    
    string_to_c_str(json!({
        "error": "Unknown error"
    }).to_string())
}

/// Configure cloud sync
#[no_mangle]
pub extern "C" fn letta_configure_sync(config_json: *const c_char) -> i32 {
    let config_str = unsafe { c_str_to_string(config_json) };
    
    let config_result: Result<serde_json::Value, _> = serde_json::from_str(&config_str);
    if config_result.is_err() {
        return -1;
    }
    
    let config_value = config_result.unwrap();
    
    let sync_config = SyncConfig {
        endpoint: config_value.get("endpoint")
            .and_then(|v| v.as_str())
            .unwrap_or("https://api.letta.ai")
            .to_string(),
        api_key: config_value.get("api_key")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        sync_interval: config_value.get("sync_interval")
            .and_then(|v| v.as_u64())
            .unwrap_or(300000), // 5 minutes
        conflict_resolution: config_value.get("conflict_resolution")
            .and_then(|v| v.as_str())
            .unwrap_or("last-write-wins")
            .to_string(),
        auto_sync: config_value.get("auto_sync")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
    };
    
    match SyncClient::new(sync_config) {
        Ok(client) => {
            *SYNC_CLIENT.lock().unwrap() = Some(client);
            0
        }
        Err(_) => -1,
    }
}

/// Sync with cloud
#[no_mangle]
pub extern "C" fn letta_sync_with_cloud(handle: *mut AgentHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }
    
    let sync_client = SYNC_CLIENT.lock().unwrap();
    if sync_client.is_none() {
        return -1; // Sync not configured
    }
    
    unsafe {
        let handle = &*handle;
        let agents = AGENTS.lock().unwrap();
        
        if handle.index >= agents.len() || agents[handle.index].is_none() {
            return -1;
        }
        
        if let Some(agent) = &agents[handle.index] {
            // Export agent state
            let state_json = agent.export_state();
            if state_json.is_err() {
                return -1;
            }
            
            // TODO: Implement actual sync with Letta server
            // For now, just return success
            return 0;
        }
    }
    
    -1
}

/// Free a string allocated by Rust
#[no_mangle]
pub extern "C" fn letta_free_str(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_ffi_agent_creation() {
        let config = r#"{"name": "test", "model": "toy"}"#;
        let c_config = CString::new(config).unwrap();
        
        let handle = letta_create_agent(c_config.as_ptr());
        assert!(!handle.is_null());
        
        letta_free_agent(handle);
    }
}