use anyhow::{Context, Result, ensure};
use serde::Serialize;
use std::{
    fs,
    path::{Path, PathBuf},
};

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub root: PathBuf,
    pub containers: Vec<PathBuf>,
    pub swift_packages: Vec<PathBuf>,
    pub diagnostics: Vec<String>,
    pub scan_truncated: bool,
}

/// Bounded filesystem discovery only: no shell, hooks, dependency resolution or Xcode execution.
pub fn inspect(root: &Path) -> Result<Project> {
    let root = root.canonicalize().context("project does not exist")?;
    ensure!(root.is_dir(), "project must be a directory");
    let mut result = Project {
        root: root.clone(),
        containers: vec![],
        swift_packages: vec![],
        diagnostics: vec![],
        scan_truncated: false,
    };
    let mut pending = vec![(root.clone(), 0)];
    let mut visited = 0;
    while let Some((dir, depth)) = pending.pop() {
        for entry in fs::read_dir(&dir)? {
            let entry = entry?;
            visited += 1;
            if visited > 10000 {
                result.scan_truncated = true;
                break;
            }
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            let ty = entry.file_type()?;
            if ty.is_symlink() || name.starts_with('.') {
                continue;
            }
            if ty.is_file() && name == "Package.swift" {
                result.swift_packages.push(path.strip_prefix(&root)?.into());
            }
            if !ty.is_dir() {
                continue;
            }
            match path.extension().and_then(|s| s.to_str()) {
                Some("xcworkspace" | "xcodeproj") => {
                    result.containers.push(path.strip_prefix(&root)?.into())
                }
                _ if [
                    "node_modules",
                    "target",
                    "build",
                    "DerivedData",
                    "Pods",
                    "Carthage",
                ]
                .contains(&name.as_str()) => {}
                _ if depth < 4 => pending.push((path, depth + 1)),
                _ => result.scan_truncated = true,
            }
        }
        if visited > 10000 {
            break;
        }
    }
    result.containers.sort();
    result.swift_packages.sort();
    if result.containers.is_empty() {
        result.diagnostics.push("No Xcode container found within scan depth; standalone Swift packages are detected but are not supported by xcode.build yet.".into());
    }
    if result.containers.len() > 1 {
        result
            .diagnostics
            .push("Multiple containers found; choose one explicitly for a build.".into());
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn scan_skips_dependencies_hidden_files_and_symlinks() -> Result<()> {
        let temp = tempfile::tempdir()?;
        for path in [
            "App.xcodeproj/project.xcworkspace",
            "Pods/Dependency.xcodeproj",
            ".cache/Hidden.xcodeproj",
        ] {
            fs::create_dir_all(temp.path().join(path))?;
        }
        fs::write(temp.path().join("Package.swift"), "// fixture")?;
        std::os::unix::fs::symlink(temp.path(), temp.path().join("loop"))?;
        let p = inspect(temp.path())?;
        assert_eq!(p.containers, vec![PathBuf::from("App.xcodeproj")]);
        assert_eq!(p.swift_packages, vec![PathBuf::from("Package.swift")]);
        Ok(())
    }
}
