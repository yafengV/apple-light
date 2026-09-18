pub mod file_search;
pub mod process;
pub mod project;

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use shipios_core::config::Config;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuildRequest {
    pub container: PathBuf,
    pub scheme: String,
    #[serde(default = "default_configuration")]
    pub configuration: String,
}
fn default_configuration() -> String {
    "Debug".into()
}

impl BuildRequest {
    pub fn command(
        &self,
        config: &Config,
        artifacts: &std::path::Path,
    ) -> Result<process::CommandSpec> {
        ensure!(
            !self.scheme.trim().is_empty() && !self.scheme.starts_with('-'),
            "scheme must be nonempty and cannot start with '-'"
        );
        ensure!(
            ["Debug", "Release"].contains(&self.configuration.as_str()),
            "configuration must be Debug or Release"
        );
        let container = config.project.join(&self.container).canonicalize()?;
        ensure!(
            container.starts_with(&config.project) && container.is_dir(),
            "container must be inside the selected project"
        );
        let flag = match container.extension().and_then(|s| s.to_str()) {
            Some("xcodeproj") => "-project",
            Some("xcworkspace") => "-workspace",
            _ => anyhow::bail!("container must be an .xcodeproj or .xcworkspace"),
        };
        Ok(process::CommandSpec {
            executable: "/usr/bin/xcodebuild".into(),
            args: vec![
                flag.into(),
                container.to_string_lossy().into_owned(),
                "-scheme".into(),
                self.scheme.clone(),
                "-configuration".into(),
                self.configuration.clone(),
                "-destination".into(),
                "generic/platform=iOS Simulator".into(),
                "-derivedDataPath".into(),
                artifacts.join("DerivedData").to_string_lossy().into_owned(),
                "-resultBundlePath".into(),
                artifacts
                    .join("build.xcresult")
                    .to_string_lossy()
                    .into_owned(),
                "-disableAutomaticPackageResolution".into(),
                "-skipPackageUpdates".into(),
                "CODE_SIGNING_ALLOWED=NO".into(),
                "build".into(),
            ],
            cwd: config.project.clone(),
            env: config.tool_environment(),
            timeout_seconds: config.build_timeout_seconds,
        })
    }
}
