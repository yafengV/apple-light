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
    pub file_name: String,
    pub expected_revision: Option<String>,
    pub config: Environment,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: String,
    pub file_name: String,
    pub name: Option<String>,
    pub error: Option<String>,
    pub inherited: bool,
    pub source_folder: String,
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

fn validate_file_name(file_name: &str) -> Result<()> {
    ensure!(
        !file_name.starts_with('.')
            && file_name.ends_with(".toml")
            && file_name.len() > 5
            && Path::new(file_name)
                .file_name()
                .and_then(|name| name.to_str())
                == Some(file_name),
        "invalid environment file name"
    );
    Ok(())
}

fn checked_path(project: &Path, file_name: &str) -> Result<PathBuf> {
    validate_file_name(file_name)?;
    check_component(&project.join(".codex"))?;
    let directory = directory(project);
    check_component(&directory)?;
    let path = directory.join(file_name);
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

fn roots(project: &Path) -> Result<Vec<PathBuf>> {
    let project = project
        .canonicalize()
        .context("project directory is unavailable")?;
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|path| path.canonicalize().unwrap_or(path));
    Ok(roots_until_boundary(&project, home.as_deref()))
}

fn roots_until_boundary(project: &Path, home: Option<&Path>) -> Vec<PathBuf> {
    let mut result = Vec::new();
    let mut current = project;
    for depth in 0..50 {
        // A parent home directory is personal Codex state, not a project environment.
        if depth > 0 && home.as_deref() == Some(current) {
            break;
        }
        result.push(current.to_path_buf());
        if current.join(".git").exists() {
            break;
        }
        let Some(parent) = current.parent() else {
            break;
        };
        current = parent;
    }
    result
}

fn selected_root(project: &Path, selection: &str) -> Result<PathBuf> {
    if !Path::new(selection).is_absolute() {
        validate_file_name(selection)?;
        return Ok(project.to_path_buf());
    }
    for root in roots(project)?.into_iter().skip(1) {
        let candidate = directory(&root);
        let Ok(relative) = Path::new(selection).strip_prefix(&candidate) else {
            continue;
        };
        let Some(file_name) = relative.to_str() else {
            continue;
        };
        if validate_file_name(file_name).is_ok()
            && candidate.join(file_name) == Path::new(selection)
        {
            return Ok(root);
        }
    }
    anyhow::bail!("environment is outside the project inheritance scope")
}

fn selected_file_name(selection: &str) -> Result<&str> {
    let file_name = Path::new(selection)
        .file_name()
        .and_then(|name| name.to_str())
        .context("invalid environment file name")?;
    validate_file_name(file_name)?;
    Ok(file_name)
}

fn read_raw(project: &Path, file_name: &str) -> Result<Option<Vec<u8>>> {
    let path = checked_path(project, file_name)?;
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

pub fn load(project: &Path, file_name: &str) -> Result<Loaded> {
    let root = selected_root(project, file_name)?;
    let Some(bytes) = read_raw(&root, selected_file_name(file_name)?)? else {
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
    let root = selected_root(project, &request.file_name)?;
    let file_name = selected_file_name(&request.file_name)?;
    let inherited = Path::new(&request.file_name).is_absolute();
    let previous = read_raw(&root, file_name)?;
    ensure!(
        !inherited || previous.is_some(),
        "inherited environment no longer exists"
    );
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
    let directory = directory(&root);
    if !directory.exists() {
        if !root.join(".codex").exists() {
            fs::create_dir(root.join(".codex"))?;
        }
        fs::create_dir(&directory)?;
    }
    checked_path(&root, file_name)?;
    let path = directory.join(file_name);
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
            read_raw(&root, file_name)?.as_deref().map(revision) == current_revision,
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
    load(project, &request.file_name)
}

pub fn list(project: &Path) -> Result<Vec<Entry>> {
    let mut entries = Vec::new();
    for (depth, root) in roots(project)?.into_iter().enumerate() {
        check_component(&root.join(".codex"))?;
        let folder = directory(&root);
        check_component(&folder)?;
        let files = match fs::read_dir(&folder) {
            Ok(files) => files,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        };
        let mut names = Vec::new();
        for file in files {
            let file = file?;
            let Some(name) = file.file_name().to_str().map(str::to_owned) else {
                continue;
            };
            if validate_file_name(&name).is_ok() {
                names.push(name);
            }
        }
        ensure!(names.len() <= 64, "too many environment files");
        names.sort_by_key(|name| (name != "environment.toml", name.clone()));
        for file_name in names {
            let id = if depth == 0 {
                file_name.clone()
            } else {
                folder.join(&file_name).to_string_lossy().into_owned()
            };
            let loaded = load(project, &id);
            entries.push(Entry {
                id,
                file_name,
                name: loaded
                    .as_ref()
                    .ok()
                    .and_then(|value| value.config.as_ref())
                    .map(|config| config.name.clone()),
                error: loaded
                    .err()
                    .map(|_| "This environment file needs attention".into()),
                inherited: depth > 0,
                source_folder: root
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or("/")
                    .to_owned(),
            });
        }
    }
    Ok(entries)
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
        let empty = load(project.path(), "environment.toml")?;
        assert!(!empty.exists);
        let saved = save(
            project.path(),
            SaveRequest {
                file_name: "environment.toml".into(),
                expected_revision: None,
                config: example(),
            },
        )?;
        assert_eq!(saved.config, Some(example()));
        assert!(
            save(
                project.path(),
                SaveRequest {
                    file_name: "environment.toml".into(),
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
                file_name: "environment.toml".into(),
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
        assert_eq!(
            load(project.path(), "environment.toml")?
                .config
                .unwrap()
                .actions[0]
                .name,
            "Run"
        );
        let outside = tempfile::tempdir()?;
        fs::remove_file(directory(project.path()).join("environment.toml"))?;
        std::os::unix::fs::symlink(
            outside.path().join("missing"),
            directory(project.path()).join("environment.toml"),
        )?;
        assert!(load(project.path(), "environment.toml").is_err());
        Ok(())
    }

    #[test]
    fn lists_multiple_files_and_reports_invalid_without_unsafe_paths() -> Result<()> {
        let project = tempfile::tempdir()?;
        let first = save(
            project.path(),
            SaveRequest {
                file_name: "environment.toml".into(),
                expected_revision: None,
                config: example(),
            },
        )?;
        assert!(first.exists);
        let mut second = example();
        second.name = "Second".into();
        save(
            project.path(),
            SaveRequest {
                file_name: "environment-2.toml".into(),
                expected_revision: None,
                config: second,
            },
        )?;
        fs::write(directory(project.path()).join("broken.toml"), "[setup\n")?;
        let entries = list(project.path())?;
        assert_eq!(entries.len(), 3);
        assert_eq!(
            entries
                .iter()
                .find(|entry| entry.file_name == "environment-2.toml")
                .and_then(|entry| entry.name.as_deref()),
            Some("Second")
        );
        assert!(
            entries
                .iter()
                .any(|entry| entry.file_name == "broken.toml" && entry.error.is_some())
        );
        assert!(load(project.path(), "../outside.toml").is_err());
        assert!(
            save(
                project.path(),
                SaveRequest {
                    file_name: "../outside.toml".into(),
                    expected_revision: None,
                    config: example()
                }
            )
            .is_err()
        );
        Ok(())
    }

    #[test]
    fn inherits_until_git_root_and_keeps_duplicate_names_distinct() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let repository = temp.path().join("repo");
        let project = repository.join("app");
        fs::create_dir_all(&project)?;
        fs::create_dir(repository.join(".git"))?;
        save(
            &repository,
            SaveRequest {
                file_name: "environment.toml".into(),
                expected_revision: None,
                config: example(),
            },
        )?;
        let mut child = example();
        child.name = "Child".into();
        save(
            &project,
            SaveRequest {
                file_name: "environment.toml".into(),
                expected_revision: None,
                config: child,
            },
        )?;
        save(
            temp.path(),
            SaveRequest {
                file_name: "outside.toml".into(),
                expected_revision: None,
                config: example(),
            },
        )?;
        let entries = list(&project)?;
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].id, "environment.toml");
        assert!(!entries[0].inherited);
        assert_eq!(
            entries[1].id,
            directory(&repository.canonicalize()?)
                .join("environment.toml")
                .to_string_lossy()
        );
        assert!(entries[1].inherited);
        assert_eq!(entries[1].source_folder, "repo");
        assert_eq!(
            load(&project, &entries[0].id)?.config.unwrap().name,
            "Child"
        );
        let inherited = load(&project, &entries[1].id)?;
        assert_eq!(inherited.config.as_ref().unwrap().name, "Example");
        let mut changed = inherited.config.unwrap();
        changed.name = "Shared".into();
        save(
            &project,
            SaveRequest {
                file_name: entries[1].id.clone(),
                expected_revision: inherited.revision,
                config: changed,
            },
        )?;
        assert_eq!(
            load(&repository, "environment.toml")?.config.unwrap().name,
            "Shared"
        );
        assert!(
            load(
                &project,
                &directory(temp.path())
                    .join("outside.toml")
                    .to_string_lossy()
            )
            .is_err()
        );
        Ok(())
    }

    #[test]
    fn project_search_does_not_read_personal_codex_home() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let home = temp.path().join("home");
        let project = home.join("projects/app");
        fs::create_dir_all(&project)?;
        let roots = roots_until_boundary(&project, Some(&home));
        assert_eq!(roots, vec![project, home.join("projects")]);
        Ok(())
    }
}
