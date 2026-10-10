use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use shipios_core::config::{Config, private_dir};
use shipios_tools::{
    BuildRequest,
    process::{self, CommandSpec},
};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};
use tokio_util::sync::CancellationToken;

const TEST: &str = "HelloShipiOSUITests/testCounterStartsAtZeroIncrementsTwiceAndResets()";
const DEVICE_NAME: &str = "ShipiOS-v0.1-Counter";
const RUNTIME: &str = "com.apple.CoreSimulator.SimRuntime.iOS-26-2";
const DEVICE_TYPE: &str = "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro";
const CONTRACT: &[(&str, &[u8])] = &[
    (
        "HelloShipiOSUITests.swift",
        include_bytes!("../../../fixtures/HelloShipiOS/HelloShipiOSUITests.swift"),
    ),
    (
        "HelloShipiOS.xcodeproj/project.pbxproj",
        include_bytes!("../../../fixtures/HelloShipiOS/HelloShipiOS.xcodeproj/project.pbxproj"),
    ),
    (
        "HelloShipiOS.xcodeproj/xcshareddata/xcschemes/HelloShipiOS.xcscheme",
        include_bytes!(
            "../../../fixtures/HelloShipiOS/HelloShipiOS.xcodeproj/xcshareddata/xcschemes/HelloShipiOS.xcscheme"
        ),
    ),
];

pub fn validate_project(project: &Path) -> Result<()> {
    let original = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/HelloShipiOS");
    ensure!(
        original.canonicalize().ok().as_deref() != Some(project),
        "Copy HelloShipiOS before verification; the repository fixture is immutable"
    );
    for (name, expected) in CONTRACT {
        let path = project.join(name);
        ensure!(
            !fs::symlink_metadata(&path)?.file_type().is_symlink(),
            "Fixed acceptance inputs cannot be symlinks"
        );
        ensure!(
            fs::read(&path)? == *expected,
            "Fixed acceptance input was changed: {name}"
        );
    }
    Ok(())
}

fn snapshot(project: &Path) -> Result<BTreeMap<String, String>> {
    fn visit(root: &Path, path: &Path, out: &mut BTreeMap<String, String>) -> Result<()> {
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name == "xcuserdata" || name.ends_with(".xcworkspace") {
                continue;
            }
            if entry.file_type()?.is_dir() {
                visit(root, &path, out)?;
            } else {
                ensure!(
                    path.canonicalize()?.starts_with(root),
                    "Source input escaped the isolated project"
                );
                out.insert(
                    path.strip_prefix(root)?.to_string_lossy().into_owned(),
                    format!("{:x}", Sha256::digest(fs::read(&path)?)),
                );
            }
        }
        Ok(())
    }
    let mut out = BTreeMap::new();
    visit(project, project, &mut out)?;
    Ok(out)
}

pub fn counter_passed(summary: &Value, tests: &Value) -> bool {
    fn visit<'a>(node: &'a Value, out: &mut Vec<&'a Value>) {
        if node["nodeType"] == "Test Case" {
            out.push(node);
        }
        if let Some(children) = node["children"].as_array() {
            for child in children {
                visit(child, out);
            }
        }
    }
    let mut leaves = Vec::new();
    if let Some(nodes) = tests["testNodes"].as_array() {
        for node in nodes {
            visit(node, &mut leaves);
        }
    }
    summary["result"] == "Passed"
        && summary["totalTestCount"].as_u64() == Some(1)
        && summary["passedTests"].as_u64() == Some(1)
        && ["failedTests", "skippedTests", "expectedFailures"]
            .iter()
            .all(|k| summary[k].as_u64() == Some(0))
        && leaves.len() == 1
        && leaves[0]["nodeIdentifier"] == TEST
        && leaves[0]["result"] == "Passed"
}

struct Workflow<'a, F> {
    config: &'a Config,
    artifacts: &'a Path,
    cancel: CancellationToken,
    started: F,
    steps: Vec<Value>,
    last_xcode: Option<Value>,
}

impl<F: Fn(Value) -> Result<()>> Workflow<'_, F> {
    async fn command(
        &mut self,
        name: &str,
        mut spec: CommandSpec,
    ) -> Result<process::CommandResult> {
        (self.started)(json!({"stage":name,"executable":spec.executable,"arguments":spec.args}))?;
        let directory = private_dir(&self.artifacts.join(name))?;
        let xcode = spec
            .executable
            .file_name()
            .is_some_and(|n| n == "xcodebuild");
        if xcode && std::env::var("SHIPIOS_STORAGE_GUARDED").as_deref() == Ok("1") {
            // The desktop launcher exits after opening the app; guard each later compiler too.
            self.config.derived_data_dir()?;
            let guard = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../script/dev_storage.py");
            let mut args = vec![
                guard.to_string_lossy().into_owned(),
                "run".into(),
                "--".into(),
                spec.executable.to_string_lossy().into_owned(),
            ];
            args.append(&mut spec.args);
            spec.args = args;
            spec.executable = "/usr/bin/python3".into();
            for key in ["SHIPIOS_STORAGE_GUARDED", "SHIPIOS_BUILD_CACHE_ROOT"] {
                if let Ok(value) = std::env::var(key) {
                    spec.env.insert(key.into(), value);
                }
            }
        }
        let output = process::execute(spec, &directory, self.cancel.clone()).await?;
        self.steps.push(json!({"stage":name,"exitCode":output.exit_code,"cancelled":output.cancelled,
            "timedOut":output.timed_out,"durationMs":output.duration_ms,"diagnostics":output.diagnostics,"logDirectory":directory}));
        if xcode {
            self.last_xcode = Some(serde_json::to_value(&output)?);
        }
        for (file, text) in [
            ("stdout.log", &output.stdout),
            ("stderr.log", &output.stderr),
        ] {
            use std::io::Write;
            let mut log = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(self.artifacts.join(file))?;
            writeln!(log, "\n[{name}]\n{text}")?;
        }
        Ok(output)
    }

    async fn xcrun(
        &mut self,
        name: &str,
        args: Vec<String>,
        timeout: u64,
    ) -> Result<process::CommandResult> {
        self.command(
            name,
            CommandSpec {
                executable: "/usr/bin/xcrun".into(),
                args,
                cwd: self.config.project.clone(),
                env: self.config.tool_environment(),
                timeout_seconds: timeout,
            },
        )
        .await
    }

    async fn verify(&mut self) -> Result<Value> {
        let listed = self
            .xcrun(
                "devices",
                vec![
                    "simctl".into(),
                    "list".into(),
                    "devices".into(),
                    "available".into(),
                    "-j".into(),
                ],
                30,
            )
            .await?;
        ensure!(
            listed.success(),
            "Could not list available Simulator devices"
        );
        let inventory: Value = serde_json::from_str(&listed.stdout)?;
        let devices: Vec<&Value> = inventory["devices"][RUNTIME]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|d| d["name"] == DEVICE_NAME && d["deviceTypeIdentifier"] == DEVICE_TYPE)
            .collect();
        ensure!(
            devices.len() <= 1,
            "Duplicate dedicated counter devices; select one explicitly before retrying"
        );
        let (id, booted) = if let Some(device) = devices.first() {
            (
                device["udid"]
                    .as_str()
                    .context("Invalid simulator identifier")?
                    .to_owned(),
                device["state"] == "Booted",
            )
        } else {
            let created = self
                .xcrun(
                    "create_device",
                    vec![
                        "simctl".into(),
                        "create".into(),
                        DEVICE_NAME.into(),
                        DEVICE_TYPE.into(),
                        RUNTIME.into(),
                    ],
                    30,
                )
                .await?;
            ensure!(
                created.success(),
                "iOS 26.2 / iPhone 16 Pro is required for the fixed counter acceptance"
            );
            (created.stdout.trim().to_owned(), false)
        };
        ensure!(
            uuid::Uuid::parse_str(&id).is_ok(),
            "Invalid simulator identifier"
        );
        if !booted {
            let boot = self
                .xcrun("boot", vec!["simctl".into(), "boot".into(), id.clone()], 30)
                .await?;
            ensure!(
                boot.success(),
                "Could not boot the dedicated counter simulator"
            );
        }
        let ready = self
            .xcrun(
                "boot_status",
                vec![
                    "simctl".into(),
                    "bootstatus".into(),
                    id.clone(),
                    "-b".into(),
                ],
                60,
            )
            .await?;
        ensure!(
            ready.success(),
            "Dedicated counter simulator did not become ready in 60 seconds"
        );
        let build = BuildRequest {
            container: PathBuf::from("HelloShipiOS.xcodeproj"),
            scheme: "HelloShipiOS".into(),
            configuration: "Debug".into(),
        };
        let mut spec = build.command(self.config, self.artifacts)?;
        for (flag, value) in [
            ("-destination", format!("platform=iOS Simulator,id={id}")),
            (
                "-derivedDataPath",
                self.config
                    .derived_data_dir()?
                    .to_string_lossy()
                    .into_owned(),
            ),
        ] {
            let index = spec.args.iter().position(|a| a == flag).unwrap();
            spec.args[index + 1] = value;
        }
        *spec.args.last_mut().unwrap() = "build-for-testing".into();
        spec.args.extend([
            "-parallel-testing-enabled".into(),
            "NO".into(),
            "-collect-test-diagnostics".into(),
            "never".into(),
        ]);
        let test_args = spec.args.clone();
        let compiled = self.command("build", spec).await?;
        ensure!(
            compiled.success(),
            "Counter compilation failed; UI verification was not run"
        );
        let mut args = test_args;
        let index = args.iter().position(|a| a == "-resultBundlePath").unwrap();
        args[index + 1] = self
            .artifacts
            .join("test.xcresult")
            .to_string_lossy()
            .into_owned();
        let index = args.iter().position(|a| a == "build-for-testing").unwrap();
        args[index] = "test-without-building".into();
        args.push(format!(
            "-only-testing:HelloShipiOSUITests/{}",
            TEST.trim_end_matches("()")
        ));
        let tested = self
            .command(
                "test",
                CommandSpec {
                    executable: "/usr/bin/xcodebuild".into(),
                    args,
                    cwd: self.config.project.clone(),
                    env: self.config.tool_environment(),
                    timeout_seconds: self.config.build_timeout_seconds,
                },
            )
            .await?;
        ensure!(
            !tested.cancelled && !tested.timed_out,
            "UI verification was cancelled or timed out"
        );
        let mut reports = Vec::new();
        for kind in ["summary", "tests"] {
            let result = self
                .xcrun(
                    kind,
                    vec![
                        "xcresulttool".into(),
                        "get".into(),
                        "test-results".into(),
                        kind.into(),
                        "--path".into(),
                        self.artifacts
                            .join("test.xcresult")
                            .to_string_lossy()
                            .into_owned(),
                        "--compact".into(),
                    ],
                    30,
                )
                .await?;
            ensure!(result.success(), "Could not read the actual XCTest result");
            let value: Value = serde_json::from_str(&result.stdout)?;
            fs::write(
                self.artifacts.join(format!("{kind}.json")),
                serde_json::to_vec_pretty(&value)?,
            )?;
            reports.push(value);
        }
        let passed = tested.success() && counter_passed(&reports[0], &reports[1]);
        Ok(
            json!({"verification":if passed {"passed"} else {"failed"},"testSummary":reports[0],
            "device":{"name":DEVICE_NAME,"udid":id,"runtime":RUNTIME}}),
        )
    }
}

pub async fn execute(
    config: &Config,
    artifacts: &Path,
    cancel: CancellationToken,
    started: impl Fn(Value) -> Result<()>,
) -> Result<Value> {
    let preflight = validate_project(&config.project).and_then(|()| snapshot(&config.project));
    let before = match preflight {
        Ok(before) => before,
        Err(error) => {
            let report = json!({
                "verification":"blocked", "errorCode":"COUNTER_PREFLIGHT_BLOCKED",
                "message":error.to_string(), "build":"not_run", "ui":"not_run",
                "steps":[], "command":null, "sourceSHA256":{}, "changedInputs":[],
                "artifactDirectory":artifacts, "modelEvidence":"not_run"
            });
            fs::write(
                artifacts.join("counter-report.json"),
                serde_json::to_vec_pretty(&report)?,
            )?;
            return Ok(report);
        }
    };
    let mut workflow = Workflow {
        config,
        artifacts,
        cancel,
        started,
        steps: Vec::new(),
        last_xcode: None,
    };
    let mut result = match workflow.verify().await {
        Ok(value) => value,
        Err(error) => {
            json!({"verification": if workflow.steps.iter().any(|s| s["stage"] == "test") {"failed"} else {"not_run"}, "message":error.to_string()})
        }
    };
    let after = match snapshot(&config.project) {
        Ok(after) => after,
        Err(error) => {
            result["verification"] = json!("failed");
            result["message"] = json!(format!("Source inputs became unavailable: {error}"));
            BTreeMap::new()
        }
    };
    let changed: Vec<&String> = before
        .keys()
        .chain(after.keys())
        .filter(|key| before.get(*key) != after.get(*key))
        .collect();
    if !changed.is_empty() || workflow.cancel.is_cancelled() {
        result["verification"] = json!("failed");
    }
    result["sourceSHA256"] = json!(before);
    result["changedInputs"] = json!(changed);
    result["steps"] = json!(workflow.steps);
    result["command"] = json!(workflow.last_xcode);
    result["artifactDirectory"] = json!(artifacts);
    result["modelEvidence"] = json!("recorded_by_desktop");
    result["note"] = json!(
        "Fixed counter UI verification only; not release readiness or real-model provenance."
    );
    fs::write(
        artifacts.join("counter-report.json"),
        serde_json::to_vec_pretty(&result)?,
    )?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_counter_result_rejects_missing_skipped_or_unrelated_tests() {
        let summary = json!({"result":"Passed","totalTestCount":1,"passedTests":1,"failedTests":0,"skippedTests":0,"expectedFailures":0});
        let tests =
            json!({"testNodes":[{"nodeType":"Test Case","nodeIdentifier":TEST,"result":"Passed"}]});
        assert!(counter_passed(&summary, &tests));
        for key in [
            "failedTests",
            "skippedTests",
            "expectedFailures",
            "totalTestCount",
            "passedTests",
        ] {
            let mut invalid = summary.clone();
            invalid[key] = json!(3);
            assert!(!counter_passed(&invalid, &tests));
            invalid.as_object_mut().unwrap().remove(key);
            assert!(!counter_passed(&invalid, &tests));
        }
        assert!(!counter_passed(&summary, &json!({"testNodes":[]})));
        assert!(!counter_passed(
            &summary,
            &json!({"testNodes":[{"nodeType":"Test Case","nodeIdentifier":"other", "result":"Passed"}]})
        ));
    }
    #[test]
    fn immutable_project_contract_is_checked_before_side_effects() -> Result<()> {
        let root = tempfile::tempdir()?;
        for (name, bytes) in CONTRACT {
            let p = root.path().join(name);
            fs::create_dir_all(p.parent().unwrap())?;
            fs::write(p, bytes)?;
        }
        validate_project(root.path())?;
        fs::write(root.path().join(CONTRACT[0].0), "weakened")?;
        assert!(validate_project(root.path()).is_err());
        Ok(())
    }
}
