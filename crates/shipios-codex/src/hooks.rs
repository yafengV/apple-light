use anyhow::{Context, Result, ensure};
use codex_config::{ConfigLayerStack, HookStateToml, HooksFile, HooksToml};
use codex_core_api::{AbsolutePathBuf, Config, Feature};
use codex_hooks::{HookListEntryHandler, HooksConfig, list_hooks};
use codex_protocol::protocol::{HookEventName, HookSource, HookTrustStatus};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet},
    path::Path,
};

/// Host-owned hook definitions and individual decisions. No bypass or managed
/// source marker is accepted. Trust hashes are checked by the pinned Core.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionHookSource {
    pub id: String,
    pub configuration: String,
    #[serde(default)]
    pub states: BTreeMap<String, HookStateToml>,
    #[serde(default)]
    pub plugin: Option<crate::SessionHookPlugin>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionHookMetadata {
    pub source_id: String,
    /// Stable within this source; private per-task home paths are not UI IDs.
    pub key: String,
    pub event_name: HookEventName,
    pub handler: serde_json::Value,
    /// The validated single-handler declaration, including MCP input and
    /// platform commands. Summary labels alone are insufficient for review.
    pub definition: serde_json::Value,
    pub matcher: Option<String>,
    pub timeout_sec: u64,
    pub status_message: Option<String>,
    pub additional_context_limit: Option<usize>,
    pub enabled: bool,
    pub current_hash: String,
    pub trust_status: HookTrustStatus,
    pub source: HookSource,
    pub plugin_id: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionHookInventory {
    pub hooks: Vec<SessionHookMetadata>,
    pub warnings: Vec<String>,
}

fn source_path(home: &Path, id: &str) -> Result<AbsolutePathBuf> {
    ensure!(
        !id.is_empty()
            && id.len() <= 128
            && id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')),
        "invalid hook source ID"
    );
    Ok(AbsolutePathBuf::from_absolute_path_checked(
        home.join("HookBindings").join(id).join("config.toml"),
    )?)
}

fn configured_stack(
    base: &ConfigLayerStack,
    home: &Path,
    sources: &[SessionHookSource],
) -> Result<ConfigLayerStack> {
    ensure!(sources.len() <= 128, "too many hook sources");
    let mut stack = base.clone();
    let mut ids = HashSet::new();
    let mut bytes = 0;
    for source in sources {
        ensure!(ids.insert(&source.id), "duplicate hook source ID");
        let path = source_path(home, &source.id)?;
        bytes += source.configuration.len();
        ensure!(
            source.configuration.len() <= 256 * 1024 && bytes <= 1024 * 1024,
            "hook configuration exceeds size limit"
        );
        let file: HooksFile = serde_json::from_str(&source.configuration)
            .with_context(|| format!("invalid hook configuration for {}", source.id))?;
        let mut state = BTreeMap::new();
        ensure!(source.states.len() <= 4096, "too many hook state entries");
        for (key, value) in &source.states {
            let parts: Vec<_> = key.split(':').collect();
            ensure!(
                parts.len() == 3
                    && codex_hooks::HOOK_EVENT_NAMES.iter().any(|event|
                // Core only applies this state to a matching discovered handler.
                event.to_lowercase().replace('_', "") == parts[0].replace('_', ""))
                    && parts[1].parse::<usize>().is_ok()
                    && parts[2].parse::<usize>().is_ok(),
                "invalid hook state key"
            );
            ensure!(
                value.trusted_hash.as_ref().is_none_or(|hash| hash
                    .strip_prefix("sha256:")
                    .is_some_and(|digest| digest.len() == 64
                        && digest.bytes().all(|byte| byte.is_ascii_hexdigit()))),
                "invalid trusted hook hash"
            );
            let prefix = if let Some(plugin) = &source.plugin {
                format!(
                    "{}:{}",
                    plugin.native_id()?.as_key(),
                    crate::hook_plugins::relative_path(source)
                )
            } else {
                path.display().to_string()
            };
            state.insert(format!("{prefix}:{key}"), value.clone());
        }
        let hooks = HooksToml {
            events: if source.plugin.is_some() {
                Default::default()
            } else {
                file.hooks
            },
            state,
        };
        let mut value = toml::Value::Table(toml::map::Map::from_iter([(
            "hooks".to_owned(),
            toml::Value::try_from(hooks)?,
        )]));
        if let Some(plugin) = &source.plugin {
            value
                .as_table_mut()
                .context("hook layer must be a table")?
                .insert(
                    "plugins".into(),
                    toml::Value::Table(toml::map::Map::from_iter([(
                        plugin.native_id()?.as_key(),
                        toml::Value::Table(toml::map::Map::from_iter([(
                            "enabled".to_owned(),
                            toml::Value::Boolean(true),
                        )])),
                    )])),
                );
        }
        // Only these app-supplied hooks are inserted. No project or user config
        // is loaded, and the existing requirement stack remains authoritative.
        stack = stack.with_user_config(&path, value)?;
    }
    Ok(stack)
}

pub fn session_hook_inventory(
    home: &Path,
    sources: &[SessionHookSource],
) -> Result<SessionHookInventory> {
    let stack = configured_stack(&ConfigLayerStack::default(), home, sources)?;
    inventory(&stack, home, sources)
}

fn inventory(
    stack: &ConfigLayerStack,
    home: &Path,
    sources: &[SessionHookSource],
) -> Result<SessionHookInventory> {
    let mut definitions = BTreeMap::new();
    for source in sources {
        let file: HooksFile = serde_json::from_str(&source.configuration)?;
        for (event, groups) in file.hooks.into_matcher_groups() {
            for (group_index, group) in groups.into_iter().enumerate() {
                for (handler_index, handler) in group.hooks.into_iter().enumerate() {
                    let key = format!(
                        "{}:{group_index}:{handler_index}",
                        codex_hooks::hook_event_key_label(event)
                    );
                    definitions.insert(
                        (source.id.clone(), key),
                        serde_json::json!({
                            "eventName": event, "matcher": group.matcher, "handler": handler
                        }),
                    );
                }
            }
        }
    }
    let paths: BTreeMap<_, _> = sources
        .iter()
        .map(|source| {
            let (path, prefix) = if source.plugin.is_some() {
                let native = crate::hook_plugins::native_source(home, source)?;
                (
                    native.source_path,
                    format!(
                        "{}:{}:",
                        native.plugin_id.as_key(),
                        native.source_relative_path
                    ),
                )
            } else {
                let path = source_path(home, &source.id)?;
                let prefix = format!("{}:", path.display());
                (path, prefix)
            };
            Ok((path, (source.id.clone(), prefix)))
        })
        .collect::<Result<_>>()?;
    let outcome = list_hooks(HooksConfig {
        feature_enabled: true,
        config_layer_stack: Some(stack.clone()),
        plugin_hook_sources: sources
            .iter()
            .filter(|source| source.plugin.is_some())
            .map(|source| crate::hook_plugins::native_source(home, source))
            .collect::<Result<_>>()?,
        // Deliberately never bypass definition trust.
        ..Default::default()
    });
    let hooks = outcome
        .hooks
        .into_iter()
        .filter_map(|hook| {
            let (source_id, prefix) = paths.get(&hook.source_path)?.clone();
            let key = hook.key.strip_prefix(&prefix)?.to_owned();
            let definition = definitions.get(&(source_id.clone(), key.clone()))?.clone();
            let handler = match hook.handler {
                HookListEntryHandler::Command { command, r#async } => serde_json::json!({
                "type": "command", "command": command, "async": r#async}),
                HookListEntryHandler::McpTool { server, tool } => serde_json::json!({
                "type": "mcp_tool", "server": server, "tool": tool}),
            };
            Some(SessionHookMetadata {
                source_id,
                key,
                event_name: hook.event_name,
                handler,
                definition,
                matcher: hook.matcher,
                timeout_sec: hook.timeout_sec,
                status_message: hook.status_message,
                additional_context_limit: hook.additional_context_limit,
                enabled: hook.enabled,
                current_hash: hook.current_hash,
                trust_status: hook.trust_status,
                source: hook.source,
                plugin_id: hook.plugin_id,
            })
        })
        .collect();
    Ok(SessionHookInventory {
        hooks,
        warnings: outcome.warnings,
    })
}

pub(crate) fn apply_session_hooks(
    config: &mut Config,
    sources: &[SessionHookSource],
) -> Result<()> {
    if sources.is_empty() {
        return Ok(());
    }
    ensure!(
        !config.bypass_hook_trust,
        "hook trust bypass is not supported by ShipiOS"
    );
    config.config_layer_stack =
        configured_stack(&config.config_layer_stack, &config.codex_home, sources)?;
    config.features.enable(Feature::CodexHooks)?;
    if sources.iter().any(|source| source.plugin.is_some()) {
        crate::hook_plugins::install(&config.codex_home, sources)?;
        config.features.enable(Feature::Plugins)?;
        config.features.disable(Feature::RemotePlugin)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn source(command: &str) -> SessionHookSource {
        SessionHookSource { id: "plugin-fixture".into(), plugin: None, configuration: serde_json::json!({
            "hooks": { "SessionStart": [{ "hooks": [{ "type": "command", "command": command,
                "timeout": 4, "async": true, "additionalContextLimit": 300, "statusMessage": "Loading" }] }] }
        }).to_string(), states: BTreeMap::new() }
    }
    #[test]
    fn inventory_checks_native_trust_and_preserves_metadata_without_execution() -> Result<()> {
        let root = tempfile::tempdir()?;
        let marker = root.path().join("must-not-run");
        let mut source = source(&format!("touch '{}'", marker.display()));
        let first = session_hook_inventory(root.path(), &[source.clone()])?;
        let hook = &first.hooks[0];
        assert_eq!(hook.trust_status, HookTrustStatus::Untrusted);
        assert_eq!(hook.handler["async"], true);
        assert_eq!(hook.timeout_sec, 4);
        assert_eq!(hook.additional_context_limit, Some(300));
        assert_eq!(hook.status_message.as_deref(), Some("Loading"));
        source.states.insert(
            hook.key.clone(),
            HookStateToml {
                enabled: Some(true),
                trusted_hash: Some(hook.current_hash.clone()),
            },
        );
        assert_eq!(
            session_hook_inventory(root.path(), &[source.clone()])?.hooks[0].trust_status,
            HookTrustStatus::Trusted
        );
        source.configuration = source.configuration.replace("touch", "echo");
        assert_eq!(
            session_hook_inventory(root.path(), &[source.clone()])?.hooks[0].trust_status,
            HookTrustStatus::Modified
        );
        assert!(!marker.exists());
        assert!(!root.path().join("HookBindings").exists());
        Ok(())
    }
    #[test]
    fn source_and_state_paths_cannot_escape_or_replace_other_configuration() -> Result<()> {
        let root = tempfile::tempdir()?;
        let mut hook = source("echo ok");
        hook.id = "../config".into();
        assert!(session_hook_inventory(root.path(), &[hook]).is_err());
        let mut hook = source("echo ok");
        hook.states
            .insert("../other:0:0".into(), HookStateToml::default());
        assert!(session_hook_inventory(root.path(), &[hook]).is_err());
        let hook = source("echo ok");
        assert!(session_hook_inventory(root.path(), &[hook.clone(), hook]).is_err());
        let mut hook = source("echo ok");
        hook.configuration = r#"{"hooks":{},"model":"other"}"#.into();
        assert!(session_hook_inventory(root.path(), &[hook]).is_err());
        Ok(())
    }

    #[test]
    fn mcp_input_is_reviewable_and_changes_invalidate_only_its_trust() -> Result<()> {
        let root = tempfile::tempdir()?;
        let mut source = SessionHookSource { id: "policy".into(), plugin: None, states: BTreeMap::new(),
            configuration: serde_json::json!({"hooks": {"PreToolUse": [{"matcher":"shell", "hooks": [
                {"type":"mcp_tool", "server":"policy", "tool":"inspect", "input":{"mode":"first","paths":["one","two"]}},
                {"type":"command", "command":"echo check"}
            ]}]}}).to_string() };
        let inventory = session_hook_inventory(root.path(), &[source.clone()])?;
        assert_eq!(inventory.hooks.len(), 2);
        assert_eq!(
            inventory.hooks[0].definition["handler"]["input"]["paths"],
            serde_json::json!(["one", "two"])
        );
        for hook in inventory.hooks {
            source.states.insert(
                hook.key,
                HookStateToml {
                    enabled: Some(true),
                    trusted_hash: Some(hook.current_hash),
                },
            );
        }
        source.configuration = source.configuration.replace("first", "second");
        let updated = session_hook_inventory(root.path(), &[source.clone()])?;
        assert_eq!(updated.hooks[0].trust_status, HookTrustStatus::Modified);
        assert_eq!(updated.hooks[1].trust_status, HookTrustStatus::Trusted);
        source
            .states
            .get_mut(&updated.hooks[1].key)
            .unwrap()
            .enabled = Some(false);
        let disabled = session_hook_inventory(root.path(), &[source])?;
        assert!(!disabled.hooks[1].enabled);
        assert_eq!(disabled.hooks[1].trust_status, HookTrustStatus::Trusted);
        Ok(())
    }
}
