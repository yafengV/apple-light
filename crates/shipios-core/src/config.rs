use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Layer {
    pub model: Option<String>,
    pub build_timeout_seconds: Option<u64>,
    pub developer_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub data_dir: PathBuf,
    pub project: PathBuf,
    pub model: Option<String>,
    pub build_timeout_seconds: u64,
    pub developer_dir: Option<PathBuf>,
    pub sources: BTreeMap<String, String>,
    pub project_config_trusted: bool,
}

impl Config {
    pub fn load(
        data_dir: &Path,
        project: &Path,
        trust_project: bool,
        overrides: Layer,
    ) -> Result<Self> {
        let project = project
            .canonicalize()
            .context("project directory does not exist")?;
        ensure!(project.is_dir(), "project must be a directory");
        let data_dir = private_dir(data_dir)?;
        for name in ["State", "Artifacts", "Agent"] {
            private_dir(&data_dir.join(name))?;
        }
        let mut config = Self {
            data_dir,
            project,
            model: None,
            build_timeout_seconds: 300,
            developer_dir: None,
            sources: BTreeMap::from([
                ("model".into(), "defaults".into()),
                ("buildTimeoutSeconds".into(), "defaults".into()),
                ("developerDir".into(), "defaults".into()),
            ]),
            project_config_trusted: trust_project,
        };
        let user = config.data_dir.join("config.toml");
        config.apply(read_layer(&user)?, user.to_string_lossy().as_ref());
        if trust_project {
            let local = config.project.join(".shipios/config.toml");
            config.apply(read_layer(&local)?, local.to_string_lossy().as_ref());
        }
        config.apply(overrides, "runtime");
        ensure!(
            (1..=3600).contains(&config.build_timeout_seconds),
            "build timeout must be between 1 and 3600 seconds"
        );
        if let Some(path) = &config.developer_dir {
            ensure!(
                path.is_absolute() && path.is_dir(),
                "developer_dir must be an existing absolute directory"
            );
        }
        if let Some(model) = &config.model {
            ensure!(!model.trim().is_empty(), "model cannot be empty");
        }
        Ok(config)
    }

    fn apply(&mut self, layer: Layer, source: &str) {
        if let Some(value) = layer.model {
            self.model = Some(value);
            self.sources.insert("model".into(), source.into());
        }
        if let Some(value) = layer.build_timeout_seconds {
            self.build_timeout_seconds = value;
            self.sources
                .insert("buildTimeoutSeconds".into(), source.into());
        }
        if let Some(value) = layer.developer_dir {
            self.developer_dir = Some(value);
            self.sources.insert("developerDir".into(), source.into());
        }
    }

    /// Intentionally does not copy the parent environment or discover Codex settings.
    pub fn tool_environment(&self) -> BTreeMap<String, String> {
        let mut env = BTreeMap::from([
            ("PATH".into(), "/usr/bin:/bin:/usr/sbin:/sbin".into()),
            ("LANG".into(), "en_US.UTF-8".into()),
            (
                "TMPDIR".into(),
                std::env::temp_dir().to_string_lossy().into_owned(),
            ),
        ]);
        if let Some(home) = std::env::var_os("HOME") {
            env.insert("HOME".into(), home.to_string_lossy().into_owned());
        }
        if let Some(dir) = &self.developer_dir {
            env.insert("DEVELOPER_DIR".into(), dir.to_string_lossy().into_owned());
        }
        env
    }
}

fn read_layer(path: &Path) -> Result<Layer> {
    if !path.exists() {
        return Ok(Layer::default());
    }
    ensure!(
        !fs::symlink_metadata(path)?.file_type().is_symlink(),
        "configuration must not be a symlink"
    );
    ensure!(
        !fs::symlink_metadata(path.parent().context("configuration has no parent")?)?
            .file_type()
            .is_symlink(),
        "configuration directory must not be a symlink"
    );
    let metadata = fs::metadata(path)?;
    ensure!(metadata.len() <= 65536, "configuration exceeds 64 KiB");
    // Do not include TOML parser excerpts: a malformed file could contain a secret.
    toml::from_str(&fs::read_to_string(path)?).map_err(|_| {
        anyhow::anyhow!(
            "invalid ShipiOS configuration at {}; check supported fields",
            path.display()
        )
    })
}

pub fn private_dir(path: &Path) -> Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    ensure!(path.is_absolute(), "data directory must be absolute");
    if path.components().any(|c| c.as_os_str() == ".codex") {
        bail!("ShipiOS data cannot be stored inside a .codex directory");
    }
    if fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink()) {
        bail!("ShipiOS data directory must not be a symlink");
    }
    // Canonicalize the existing ancestor before creating anything to reject aliases to Codex.
    let mut ancestor = path;
    while !ancestor.exists() {
        ancestor = ancestor.parent().context("no existing data ancestor")?;
    }
    ensure!(
        !ancestor
            .canonicalize()?
            .components()
            .any(|c| c.as_os_str() == ".codex"),
        "ShipiOS data cannot resolve into .codex"
    );
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)?;
    let path = path.canonicalize()?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn config_is_explicit_and_project_trust_is_required() -> Result<()> {
        let tmp = tempfile::tempdir()?;
        let data = private_dir(&tmp.path().join("data"))?;
        let project = private_dir(&tmp.path().join("project"))?;
        fs::create_dir(project.join(".codex"))?;
        fs::write(project.join(".codex/config.toml"), "model = 'poison'")?;
        fs::write(
            data.join("config.toml"),
            "model = 'user'\nbuild_timeout_seconds = 30",
        )?;
        fs::create_dir(project.join(".shipios"))?;
        fs::write(project.join(".shipios/config.toml"), "model = 'project'")?;
        let c = Config::load(&data, &project, false, Layer::default())?;
        assert_eq!(c.model.as_deref(), Some("user"));
        let c = Config::load(&data, &project, true, Layer::default())?;
        assert_eq!(c.model.as_deref(), Some("project"));
        let c = Config::load(
            &data,
            &project,
            true,
            Layer {
                model: Some("override".into()),
                ..Default::default()
            },
        )?;
        assert_eq!(c.model.as_deref(), Some("override"));
        assert_eq!(c.sources["model"], "runtime");
        assert!(!c.tool_environment().contains_key("OPENAI_API_KEY"));
        assert!(!c.tool_environment().contains_key("CODEX_HOME"));
        Ok(())
    }

    #[test]
    fn invalid_settings_and_codex_aliases_are_rejected() -> Result<()> {
        let tmp = tempfile::tempdir()?;
        let data = private_dir(&tmp.path().join("data"))?;
        fs::write(data.join("config.toml"), "api_key = 'do-not-print-this'")?;
        let error = Config::load(&data, tmp.path(), false, Layer::default())
            .unwrap_err()
            .to_string();
        assert!(!error.contains("do-not-print-this"));
        let codex = tmp.path().join(".codex");
        fs::create_dir(&codex)?;
        std::os::unix::fs::symlink(&codex, tmp.path().join("alias"))?;
        assert!(private_dir(&tmp.path().join("alias/child")).is_err());
        assert!(!codex.join("child").exists());
        Ok(())
    }
}
