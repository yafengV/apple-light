use anyhow::{Context, Result, ensure};
use codex_core_api::AbsolutePathBuf;
use codex_core_plugins::store::{DEFAULT_PLUGIN_VERSION, PluginStore};
use codex_plugin::{PluginHookSource, PluginId};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs,
    io::Read,
    path::{Path, PathBuf},
};

use crate::hooks::SessionHookSource;

/// The wire carries only an installation ID and resource digest. The Agent
/// resolves roots under its own app data directory; RPC cannot provide paths.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionHookPlugin {
    pub id: String,
    pub fingerprint: String,
    #[serde(skip)]
    app_root: Option<PathBuf>,
}

impl SessionHookPlugin {
    pub fn bind_app_root(&mut self, root: &Path) -> Result<()> {
        ensure!(
            self.id.len() <= 64
                && self
                    .id
                    .as_bytes()
                    .first()
                    .is_some_and(u8::is_ascii_alphanumeric)
                && self
                    .id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')),
            "invalid hook plugin ID"
        );
        ensure!(
            self.fingerprint.len() == 64 && self.fingerprint.bytes().all(|b| b.is_ascii_hexdigit()),
            "invalid hook plugin fingerprint"
        );
        self.app_root = Some(root.canonicalize()?);
        self.resources()?;
        Ok(())
    }

    pub(crate) fn native_id(&self) -> Result<PluginId> {
        // Encode rather than normalize: every allowed host ID has a distinct
        // native ID, including names not accepted by Core's dot grammar.
        let name = format!(
            "p{}",
            self.id
                .bytes()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        );
        Ok(PluginId::new(name, "shipios-hooks".into())?)
    }

    fn package_root(&self) -> Result<PathBuf> {
        let root = self
            .app_root
            .as_ref()
            .context("hook plugin is not bound by the Agent")?;
        let package = root.join("Plugins").join(&self.id);
        ensure!(
            package.symlink_metadata()?.is_dir() && package.canonicalize()? == package,
            "hook plugin package escaped app data root"
        );
        Ok(package)
    }

    fn resources(&self) -> Result<Vec<Resource>> {
        let resources = read_resources(&self.package_root()?)?;
        ensure!(
            fingerprint(&resources) == self.fingerprint,
            "hook plugin resources changed; reload Hooks"
        );
        Ok(resources)
    }

    fn persistent_data(&self) -> Result<PathBuf> {
        let root = self
            .app_root
            .as_ref()
            .context("hook plugin is not bound by the Agent")?;
        private_directory(&root.join("Hooks"))?;
        private_directory(&root.join("Hooks/PluginData"))?;
        let data = root
            .join("Hooks/PluginData")
            .join(self.native_id()?.plugin_name);
        private_directory(&data)?;
        Ok(data)
    }
}

pub(crate) fn relative_path(source: &SessionHookSource) -> String {
    format!(".shipios-hooks/{}.json", source.id)
}

pub(crate) fn native_source(home: &Path, source: &SessionHookSource) -> Result<PluginHookSource> {
    let plugin = source.plugin.as_ref().context("missing hook plugin")?;
    let id = plugin.native_id()?;
    let store = PluginStore::try_new(home.to_owned())?;
    let root = store.plugin_root(&id, DEFAULT_PLUGIN_VERSION);
    let file: codex_config::HooksFile = serde_json::from_str(&source.configuration)?;
    Ok(PluginHookSource {
        plugin_id: id.clone(),
        plugin_root: root.clone(),
        plugin_data_root: store.plugin_data_root(&id),
        source_path: root.join(relative_path(source)),
        source_relative_path: relative_path(source),
        hooks: file.hooks,
    })
}

/// Project only Hook capabilities into Core's native local plugin store. The
/// pinned portable loader does not yet load portable Hook extensions, so both
/// package formats use an app-owned legacy manifest and exact raw definitions.
/// Resources are copied unchanged; no command or environment rewriting occurs.
pub(crate) fn install(home: &Path, sources: &[SessionHookSource]) -> Result<()> {
    let mut groups: BTreeMap<&str, Vec<&SessionHookSource>> = BTreeMap::new();
    for source in sources {
        if let Some(plugin) = &source.plugin {
            groups.entry(&plugin.id).or_default().push(source);
        }
    }
    if groups.is_empty() {
        return Ok(());
    }
    private_directory(home)?;
    for component in [
        "plugins",
        "plugins/cache",
        "plugins/data",
        "HookPluginStaging",
    ] {
        private_directory(&home.join(component))?;
    }
    let store = PluginStore::try_new(home.to_owned())?;
    for group in groups.values() {
        let plugin = group[0].plugin.as_ref().context("missing hook plugin")?;
        ensure!(
            group.iter().all(|source| source
                .plugin
                .as_ref()
                .is_some_and(|other| other.fingerprint == plugin.fingerprint
                    && other.app_root == plugin.app_root)),
            "inconsistent hook plugin snapshots"
        );
        let resources = plugin.resources()?;
        let staged = tempfile::Builder::new()
            .prefix("plugin-")
            .tempdir_in(home.join("HookPluginStaging"))?;
        for resource in &resources {
            let path = staged.path().join(&resource.path);
            if resource.directory {
                fs::create_dir_all(&path)?;
            } else {
                fs::create_dir_all(path.parent().context("resource parent")?)?;
                fs::write(&path, &resource.bytes)?;
            }
        }
        for resource in &resources {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(
                    staged.path().join(&resource.path),
                    fs::Permissions::from_mode(resource.mode & 0o777),
                )?;
            }
        }
        // A portable root manifest takes precedence over the legacy one.
        let portable = staged.path().join("plugin.json");
        if portable.exists() {
            fs::remove_file(portable)?;
        }
        let generated = staged.path().join(".shipios-hooks");
        ensure!(
            !generated.exists(),
            "plugin uses reserved .shipios-hooks resource directory"
        );
        fs::create_dir(&generated)?;
        fs::create_dir(generated.join("empty"))?;
        fs::write(generated.join("apps.json"), r#"{"apps":[]}"#)?;
        for source in group {
            fs::write(
                staged.path().join(relative_path(source)),
                &source.configuration,
            )?;
        }
        fs::create_dir_all(staged.path().join(".codex-plugin"))?;
        let id = plugin.native_id()?;
        fs::write(
            staged.path().join(".codex-plugin/plugin.json"),
            serde_json::to_vec(&serde_json::json!({
                "name": id.plugin_name, "hooks": group.iter().map(|s| format!("./{}", relative_path(s))).collect::<Vec<_>>(),
                "skills": ["./.shipios-hooks/empty"], "commands": ["./.shipios-hooks/empty"],
                "mcpServers": {}, "apps": "./.shipios-hooks/apps.json"
            }))?,
        )?;
        private_directory(store.root().join("shipios-hooks").as_path())?;
        let base = store.plugin_base_root(&id);
        private_directory(base.as_path())?;
        store.install_with_version(
            AbsolutePathBuf::from_absolute_path_checked(staged.path())?,
            id.clone(),
            DEFAULT_PLUGIN_VERSION.to_owned(),
        )?;
        let data = plugin.persistent_data()?;
        let link = store.plugin_data_root(&id);
        match fs::symlink_metadata(&link) {
            Ok(metadata) => ensure!(
                metadata.file_type().is_symlink()
                    && fs::read_link(&link)? == data
                    && link.canonicalize()?.as_path() == data,
                "unexpected plugin data binding"
            ),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                #[cfg(unix)]
                std::os::unix::fs::symlink(&data, &link)?;
                #[cfg(not(unix))]
                anyhow::bail!("native plugin data binding requires Unix");
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

fn private_directory(path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .context("private Hook directory has no parent")?;
    ensure!(
        parent.canonicalize()? == parent,
        "private Hook directory parent escaped its root"
    );
    fs::create_dir_all(path)?;
    ensure!(
        path.symlink_metadata()?.is_dir() && path.canonicalize()? == path,
        "private Hook directory escaped its root"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

struct Resource {
    path: String,
    directory: bool,
    mode: u32,
    bytes: Vec<u8>,
}

fn read_resources(root: &Path) -> Result<Vec<Resource>> {
    let mut values = Vec::new();
    let mut pending = vec![root.to_owned()];
    let mut total = 0;
    let mut file_count = 0;
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            let path = entry.path();
            let metadata = path.symlink_metadata()?;
            ensure!(
                metadata.is_dir() || metadata.is_file(),
                "Hook plugin contains a link or special resource"
            );
            ensure!(
                path.canonicalize()? == path,
                "Hook plugin resource escaped package"
            );
            let relative = path
                .strip_prefix(root)?
                .to_str()
                .context("plugin resource path is not UTF-8")?
                .to_owned();
            if metadata.is_file() {
                file_count += 1;
            }
            ensure!(
                relative.split('/').count() <= 32 && file_count <= 2000 && values.len() < 10_000,
                "Hook plugin resource count or depth exceeded"
            );
            let mut bytes = Vec::new();
            if metadata.is_dir() {
                pending.push(path.clone());
            } else {
                ensure!(
                    metadata.len() <= 50 * 1024 * 1024 - total,
                    "Hook plugin resources exceed 50 MiB"
                );
                let mut options = fs::OpenOptions::new();
                options.read(true);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::OpenOptionsExt;
                    options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
                }
                let file = options.open(&path)?;
                ensure!(
                    file.metadata()?.is_file(),
                    "Hook plugin resource changed type"
                );
                file.take(metadata.len() + 1).read_to_end(&mut bytes)?;
                ensure!(
                    bytes.len() as u64 == metadata.len(),
                    "Hook plugin resource changed size"
                );
                total += bytes.len() as u64;
            }
            #[cfg(unix)]
            let mode = {
                use std::os::unix::fs::MetadataExt;
                metadata.mode() & 0o177777
            };
            #[cfg(not(unix))]
            let mode = if metadata.is_dir() {
                0o040755
            } else {
                0o100644
            };
            values.push(Resource {
                path: relative,
                directory: metadata.is_dir(),
                mode,
                bytes,
            });
        }
    }
    values.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(values)
}

fn fingerprint(values: &[Resource]) -> String {
    let mut digest = Sha256::new();
    for resource in values {
        digest.update(resource.path.as_bytes());
        digest.update([0]);
        digest.update(resource.mode.to_be_bytes());
        digest.update((resource.bytes.len() as u64).to_be_bytes());
        digest.update(&resource.bytes);
    }
    format!("{:x}", digest.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session_hook_inventory;
    use codex_config::HookStateToml;

    fn fixture(root: &Path) -> Result<SessionHookSource> {
        let package = root.join("Plugins/fixture");
        fs::create_dir_all(package.join("scripts"))?;
        fs::create_dir_all(package.join("skills/extra"))?;
        fs::write(
            package.join("plugin.json"),
            r#"{"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"fixture"}"#,
        )?;
        fs::write(package.join("scripts/run.sh"), "printf resource")?;
        fs::write(
            package.join("skills/extra/SKILL.md"),
            "---\nname: extra\ndescription: extra\n---\nDo something",
        )?;
        fs::write(
            package.join(".mcp.json"),
            r#"{"mcpServers":{"must-not-load":{"command":"false"}}}"#,
        )?;
        let mut plugin: SessionHookPlugin = serde_json::from_value(serde_json::json!({
            "id":"fixture", "fingerprint":fingerprint(&read_resources(&package)?)
        }))?;
        plugin.bind_app_root(root)?;
        Ok(SessionHookSource {
            id: "source".into(),
            plugin: Some(plugin),
            states: BTreeMap::new(),
            configuration: serde_json::json!({"hooks":{"SessionStart":[{"hooks":[{
                "type":"command", "command":"/bin/sh \"$PLUGIN_ROOT/scripts/run.sh\""
            }]}]}})
            .to_string(),
        })
    }

    #[test]
    fn native_projection_preserves_hashes_resources_and_data_without_other_capabilities()
    -> Result<()> {
        let temporary = tempfile::tempdir()?;
        let root = temporary.path().canonicalize()?;
        let mut source = fixture(root.as_path())?;
        let home = root.as_path().join("One");
        let native = session_hook_inventory(&home, std::slice::from_ref(&source))?;
        assert_eq!(native.hooks.len(), 1);
        assert_eq!(
            native.hooks[0].source,
            codex_protocol::protocol::HookSource::Plugin
        );
        let mut legacy = source.clone();
        legacy.plugin = None;
        let old = session_hook_inventory(&home, &[legacy])?;
        assert_eq!(
            old.hooks[0].current_hash, native.hooks[0].current_hash,
            "Origin migration must not silently replace definition trust"
        );
        source.states.insert(
            native.hooks[0].key.clone(),
            HookStateToml {
                enabled: Some(false),
                trusted_hash: Some(native.hooks[0].current_hash.clone()),
            },
        );
        install(&home, std::slice::from_ref(&source))?;
        let store = PluginStore::try_new(home.clone())?;
        let id = source.plugin.as_ref().unwrap().native_id()?;
        let installed = store
            .active_plugin_root(&id)
            .context("missing native cache")?;
        assert_eq!(
            fs::read_to_string(installed.join("scripts/run.sh"))?,
            "printf resource"
        );
        let manifest = codex_core_plugins::manifest::load_plugin_manifest(installed.as_path())
            .context("missing native manifest")?;
        let (loaded, warnings) = codex_core_plugins::loader::load_plugin_hooks(
            &installed,
            &id,
            &store.plugin_data_root(&id),
            &manifest.paths,
        );
        assert!(warnings.is_empty());
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].source_relative_path, relative_path(&source));
        assert_eq!(loaded[0].plugin_id, id);
        assert!(
            manifest
                .paths
                .skills
                .iter()
                .all(|path| path.ends_with(".shipios-hooks/empty"))
        );
        assert!(
            matches!(&manifest.paths.mcp_servers, Some(codex_core_plugins::manifest::PluginManifestMcpServers::Object(servers)) if servers == "{}")
        );
        let reviewed = session_hook_inventory(&home, std::slice::from_ref(&source))?;
        assert!(!reviewed.hooks[0].enabled);
        assert_eq!(reviewed.hooks[0].current_hash, native.hooks[0].current_hash);
        fs::write(store.plugin_data_root(&id).join("count"), "persisted")?;
        let other = root.as_path().join("Two");
        install(&other, &[source])?;
        assert_eq!(
            fs::read_to_string(
                PluginStore::try_new(other)?
                    .plugin_data_root(&id)
                    .join("count")
            )?,
            "persisted"
        );
        assert!(
            fs::read_dir(home.join("HookPluginStaging"))?
                .next()
                .is_none()
        );
        Ok(())
    }

    #[test]
    fn changed_or_escaped_plugin_resources_cannot_be_installed() -> Result<()> {
        let temporary = tempfile::tempdir()?;
        let root = temporary.path().canonicalize()?;
        let source = fixture(root.as_path())?;
        let resource = root.as_path().join("Plugins/fixture/scripts/run.sh");
        fs::write(&resource, "printf changed")?;
        assert!(install(&root.as_path().join("Task"), std::slice::from_ref(&source)).is_err());
        assert!(
            !root
                .as_path()
                .join("Task/plugins/cache/shipios-hooks")
                .exists()
        );
        #[cfg(unix)]
        {
            fs::remove_file(&resource)?;
            std::os::unix::fs::symlink(root.as_path().join("outside"), resource)?;
            assert!(source.plugin.as_ref().unwrap().resources().is_err());
        }
        assert!(
            serde_json::from_value::<SessionHookPlugin>(serde_json::json!({
                "id":"fixture", "fingerprint":"0".repeat(64), "appRoot":"/outside"
            }))
            .is_err()
        );
        let mut invalid: SessionHookPlugin = serde_json::from_value(serde_json::json!({
            "id":"../fixture", "fingerprint":"0".repeat(64)
        }))?;
        assert!(invalid.bind_app_root(root.as_path()).is_err());
        Ok(())
    }

    #[test]
    fn unexpected_data_link_never_retargets_persistent_plugin_data() -> Result<()> {
        let temporary = tempfile::tempdir()?;
        let root = temporary.path().canonicalize()?;
        let source = fixture(root.as_path())?;
        let home = root.as_path().join("Task");
        install(&home, std::slice::from_ref(&source))?;
        let store = PluginStore::try_new(home.clone())?;
        let link = store.plugin_data_root(&source.plugin.as_ref().unwrap().native_id()?);
        let outside = root.as_path().join("Outside");
        fs::create_dir(&outside)?;
        fs::write(outside.join("keep"), "unchanged")?;
        fs::remove_file(&link)?;
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, &link)?;
        assert!(install(&home, &[source]).is_err());
        assert_eq!(fs::read_to_string(outside.join("keep"))?, "unchanged");
        assert_eq!(fs::read_link(link)?, outside);
        Ok(())
    }
}
