use serde::{Deserialize, Serialize};
use chrono::{DateTime, Utc};
use reqwest::Client;
use std::time::Duration;
use letta_core::af::{AgentFileV1, AgentFile};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncConfig {
    pub endpoint: String,
    pub api_key: String,
    pub sync_interval: u64, // milliseconds
    pub conflict_resolution: String,
    pub auto_sync: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncRequest {
    pub agent_id: String,
    pub agent_file: AgentFileV1,
    pub local_version: i64,
    pub device_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncResponse {
    pub agent_file: Option<AgentFileV1>,
    pub cloud_version: i64,
    pub conflicts: Vec<ConflictInfo>,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConflictInfo {
    pub field: String,
    pub local_value: serde_json::Value,
    pub cloud_value: serde_json::Value,
    pub resolution: String,
}

pub struct SyncClient {
    config: SyncConfig,
    client: Client,
    device_id: String,
}

impl SyncClient {
    pub fn new(config: SyncConfig) -> Result<Self, Box<dyn std::error::Error>> {
        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .build()?;
        
        let device_id = uuid::Uuid::new_v4().to_string();
        
        Ok(Self {
            config,
            client,
            device_id,
        })
    }
    
    pub async fn sync_agent(&self, agent_file: &AgentFileV1, local_version: i64) -> Result<SyncResponse, Box<dyn std::error::Error>> {
        let agent_id = agent_file.agents.first()
            .map(|a| a.id.clone())
            .ok_or("No agent in file")?;
        
        let request = SyncRequest {
            agent_id,
            agent_file: agent_file.clone(),
            local_version,
            device_id: self.device_id.clone(),
        };
        
        let response = self.client
            .post(&format!("{}/v1/agents/sync", self.config.endpoint))
            .header("Authorization", format!("Bearer {}", self.config.api_key))
            .json(&request)
            .send()
            .await?;
        
        if !response.status().is_success() {
            return Err(format!("Sync failed: {}", response.status()).into());
        }
        
        let sync_response: SyncResponse = response.json().await?;
        Ok(sync_response)
    }
    
    pub async fn pull_agent(&self, agent_id: &str) -> Result<Option<AgentFileV1>, Box<dyn std::error::Error>> {
        let response = self.client
            .get(&format!("{}/v1/agents/{}/export", self.config.endpoint, agent_id))
            .header("Authorization", format!("Bearer {}", self.config.api_key))
            .send()
            .await?;
        
        if response.status() == 404 {
            return Ok(None);
        }
        
        if !response.status().is_success() {
            return Err(format!("Pull failed: {}", response.status()).into());
        }
        
        let agent_file: AgentFileV1 = response.json().await?;
        Ok(Some(agent_file))
    }
    
    pub async fn push_agent(&self, agent_file: &AgentFileV1) -> Result<(), Box<dyn std::error::Error>> {
        let agent_id = agent_file.agents.first()
            .map(|a| a.id.clone())
            .ok_or("No agent in file")?;
        
        let response = self.client
            .put(&format!("{}/v1/agents/{}/import", self.config.endpoint, agent_id))
            .header("Authorization", format!("Bearer {}", self.config.api_key))
            .json(agent_file)
            .send()
            .await?;
        
        if !response.status().is_success() {
            return Err(format!("Push failed: {}", response.status()).into());
        }
        
        Ok(())
    }
    
    pub fn resolve_conflict(&self, conflict: &ConflictInfo) -> serde_json::Value {
        match self.config.conflict_resolution.as_str() {
            "last-write-wins" => conflict.local_value.clone(),
            "cloud-wins" => conflict.cloud_value.clone(),
            "merge" => {
                // Simple merge strategy: combine if both are objects
                if conflict.local_value.is_object() && conflict.cloud_value.is_object() {
                    let mut merged = conflict.cloud_value.clone();
                    if let Some(local_obj) = conflict.local_value.as_object() {
                        if let Some(merged_obj) = merged.as_object_mut() {
                            for (k, v) in local_obj {
                                merged_obj.insert(k.clone(), v.clone());
                            }
                        }
                    }
                    merged
                } else {
                    conflict.local_value.clone()
                }
            }
            _ => conflict.local_value.clone(),
        }
    }
}

// Background sync task
pub struct SyncManager {
    client: SyncClient,
    storage: letta_storage::Storage,
}

impl SyncManager {
    pub fn new(client: SyncClient, storage: letta_storage::Storage) -> Self {
        Self { client, storage }
    }
    
    pub async fn start_auto_sync(&self) {
        if !self.client.config.auto_sync {
            return;
        }
        
        let interval = Duration::from_millis(self.client.config.sync_interval);
        
        loop {
            tokio::time::sleep(interval).await;
            
            // Get all agents that need syncing
            match self.storage.list_agents() {
                Ok(agents) => {
                    for agent in agents {
                        // Check sync metadata
                        if let Ok(Some(metadata)) = self.storage.get_sync_metadata("agent", &agent.id) {
                            if metadata.sync_status == "pending" {
                                // Perform sync
                                // TODO: Convert agent to AF and sync
                                tracing::info!("Auto-syncing agent {}", agent.id);
                            }
                        }
                    }
                }
                Err(e) => {
                    tracing::error!("Failed to list agents for sync: {}", e);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_sync_config() {
        let config = SyncConfig {
            endpoint: "https://api.letta.ai".to_string(),
            api_key: "test-key".to_string(),
            sync_interval: 300000,
            conflict_resolution: "last-write-wins".to_string(),
            auto_sync: true,
        };
        
        assert_eq!(config.endpoint, "https://api.letta.ai");
        assert_eq!(config.sync_interval, 300000);
    }
    
    #[test]
    fn test_conflict_resolution() {
        let config = SyncConfig {
            endpoint: "test".to_string(),
            api_key: "test".to_string(),
            sync_interval: 0,
            conflict_resolution: "last-write-wins".to_string(),
            auto_sync: false,
        };
        
        let client = SyncClient::new(config).unwrap();
        
        let conflict = ConflictInfo {
            field: "test".to_string(),
            local_value: serde_json::json!({"a": 1}),
            cloud_value: serde_json::json!({"b": 2}),
            resolution: "".to_string(),
        };
        
        let resolved = client.resolve_conflict(&conflict);
        assert_eq!(resolved, serde_json::json!({"a": 1}));
    }
}