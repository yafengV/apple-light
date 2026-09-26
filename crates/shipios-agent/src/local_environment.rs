//! The project-owned Codex local environment, separate from ShipiOS credentials and state.
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

const MAX_BYTES: u64 = 32 * 1024;

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PlatformScripts {
    pub script: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub darwin: Option<Script>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub linux: Option<Script>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub win32: Option<Script>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Script {
    pub script: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Action {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    pub command: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Environment {
    pub version: u32,
    pub name: String,
    pub setup: PlatformScripts,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cleanup: Option<PlatformScripts>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub actions: Vec<Action>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Loaded {
    pub exists: bool,
    pub revision: Option<String>,
    pub config: Option<Environment>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SaveRequest {
    pub expected_revision: Option<String>,
    pub config: Environment,
}

fn directory(project: &Path) -> PathBuf {
    project.join(".codex/environments")
}

fn check_component(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => ensure!(
            metadata.file_type().is_dir(),
            "environment path is not a directory"
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

fn checked_path(project: &Path) -> Result<PathBuf> {
    check_component(&project.join(".codex"))?;
    let directory = directory(project);
    check_component(&directory)?;
    let path = directory.join("environment.toml");
    match fs::symlink_metadata(&path) {
        Ok(metadata) => ensure!(
            metadata.file_type().is_file(),
            "environment file is not a regular file"
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    Ok(path)
}

fn read_raw(project: &Path) -> Result<Option<Vec<u8>>> {
    let path = checked_path(project)?;
    match fs::metadata(&path) {
        Ok(metadata) => {
            ensure!(
                metadata.len() <= MAX_BYTES,
                "environment file exceeds 32 KiB"
            );
            let bytes = fs::read(&path).context("cannot read environment file")?;
            ensure!(
                bytes.len() as u64 <= MAX_BYTES,
                "environment file exceeds 32 KiB"
            );
            Ok(Some(bytes))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn revision(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn validate(config: &Environment) -> Result<()> {
    ensure!(config.version == 1, "unsupported environment version");
    ensure!(
        !config.name.trim().is_empty(),
        "environment name is required"
    );
    for action in &config.actions {
        ensure!(!action.name.trim().is_empty(), "action name is required");
        ensure!(
            !action.command.trim().is_empty(),
            "action command is required"
        );
        if let Some(icon) = &action.icon {
            ensure!(
                ["tool", "run", "debug", "test"].contains(&icon.as_str()),
                "unsupported action icon"
            );
        }
        if let Some(platform) = &action.platform {
            ensure!(
                ["darwin", "linux", "win32"].contains(&platform.as_str()),
                "unsupported action platform"
            );
        }
    }
    Ok(())
}

pub fn load(project: &Path) -> Result<Loaded> {
    let Some(bytes) = read_raw(project)? else {
        return Ok(Loaded {
            exists: false,
            revision: None,
            config: None,
        });
    };
    let source = std::str::from_utf8(&bytes).context("environment file is not UTF-8")?;
    // Do not include parser excerpts: scripts may contain private values.
    let config: Environment = toml::from_str(source)
        .map_err(|_| anyhow::anyhow!("invalid or unsupported environment file"))?;
    validate(&config)?;
    Ok(Loaded {
        exists: true,
        revision: Some(revision(&bytes)),
        config: Some(config),
    })
}

pub fn save(project: &Path, request: SaveRequest) -> Result<Loaded> {
    validate(&request.config)?;
    let previous = read_raw(project)?;
    let current_revision = previous.as_deref().map(revision);
    ensure!(
        current_revision == request.expected_revision,
        "environment file changed outside ShipiOS; reload before saving"
    );
    let mut source = String::from("# THIS IS AUTOGENERATED. DO NOT EDIT MANUALLY\n");
    source.push_str(&toml::to_string_pretty(&request.config)?);
    ensure!(
        source.len() as u64 <= MAX_BYTES,
        "environment file exceeds 32 KiB"
    );
    let directory = directory(project);
    if !directory.exists() {
        if !project.join(".codex").exists() {
            fs::create_dir(project.join(".codex"))?;
        }
        fs::create_dir(&directory)?;
    }
    checked_path(project)?;
    let path = directory.join("environment.toml");
    let temporary = directory.join(format!(".environment-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(source.as_bytes())?;
        file.sync_all()?;
        // Recheck just before replacement; a concurrent external edit must survive.
        ensure!(
            read_raw(project)?.as_deref().map(revision) == current_revision,
            "environment file changed outside ShipiOS; reload before saving"
        );
        fs::rename(&temporary, &path)?;
        File::open(&directory)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result?;
    load(project)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn example() -> Environment {
        Environment {
            version: 1,
            name: "Example".into(),
            setup: PlatformScripts {
                script: "echo default".into(),
                darwin: Some(Script {
                    script: "echo mac".into(),
                }),
                ..Default::default()
            },
            cleanup: Some(PlatformScripts {
                script: "echo cleanup".into(),
                ..Default::default()
            }),
            actions: vec![Action {
                name: "Run".into(),
                icon: Some("run".into()),
                command: "./script/run.sh".into(),
                platform: Some("darwin".into()),
            }],
        }
    }

    #[test]
    fn load_save_roundtrip_and_conflict() -> Result<()> {
        let project = tempfile::tempdir()?;
        let empty = load(project.path())?;
        assert!(!empty.exists);
        let saved = save(
            project.path(),
            SaveRequest {
                expected_revision: None,
                config: example(),
            },
        )?;
        assert_eq!(saved.config, Some(example()));
        assert!(
            save(
                project.path(),
                SaveRequest {
                    expected_revision: None,
                    config: example()
                }
            )
            .is_err()
        );
        let mut changed = example();
        changed.name = "Changed".into();
        let updated = save(
            project.path(),
            SaveRequest {
                expected_revision: saved.revision,
                config: changed.clone(),
            },
        )?;
        assert_eq!(updated.config, Some(changed));
        Ok(())
    }

    #[test]
    fn reads_codex_format_and_refuses_symlinks() -> Result<()> {
        let project = tempfile::tempdir()?;
        fs::create_dir_all(directory(project.path()))?;
        fs::write(
            directory(project.path()).join("environment.toml"),
            "version = 1\nname = 'Example'\n[setup]\nscript = ''\n[[actions]]\nname = 'Run'\nicon = 'run'\ncommand = './run.sh'\n",
        )?;
        assert_eq!(load(project.path())?.config.unwrap().actions[0].name, "Run");
        let outside = tempfile::tempdir()?;
        fs::remove_file(directory(project.path()).join("environment.toml"))?;
        std::os::unix::fs::symlink(
            outside.path().join("missing"),
            directory(project.path()).join("environment.toml"),
        )?;
        assert!(load(project.path()).is_err());
        Ok(())
    }
}
