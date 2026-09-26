mod codex_bridge;
mod rpc;
mod service;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use shipios_core::config::{Config, Layer};
use shipios_tools::BuildRequest;
use std::{path::PathBuf, sync::Arc};

#[derive(Parser)]
#[command(
    version,
    about = "ShipiOS local agent — project diagnostics, iOS Simulator builds and isolated Codex threads."
)]
struct Args {
    #[arg(long, global = true)]
    data_dir: Option<PathBuf>,
    #[arg(long, global = true, default_value = ".")]
    project: PathBuf,
    #[arg(long, global = true)]
    trust_project_config: bool,
    #[arg(long, global = true)]
    build_timeout_seconds: Option<u64>,
    #[command(subcommand)]
    command: Action,
}

#[derive(Subcommand)]
enum Action {
    /// Newline-delimited JSON-RPC 2.0 over stdin/stdout.
    Serve,
    /// Show effective settings and where each setting came from.
    Config,
    /// Discover Xcode containers without executing project code.
    Inspect,
    /// Inspect the project and run xcodebuild -version.
    Doctor,
    /// Build an explicit scheme for iOS Simulator (executes project build phases).
    Build {
        #[arg(long)]
        container: PathBuf,
        #[arg(long)]
        scheme: String,
        #[arg(long, default_value = "Debug")]
        configuration: String,
    },
    /// List persisted runs; unfinished runs from an earlier process become interrupted.
    Runs,
    /// Read-only workspace path search; does not load configuration or create state.
    SearchFiles {
        #[arg(long, allow_hyphen_values = true)]
        query: String,
    },
    /// Stream queries/results over stdio while reusing the workspace index.
    SearchFilesSession,
}

fn main() -> Result<()> {
    // Dispatch only the helper modes required by Codex tools. The upstream
    // arg0 wrapper also reads ~/.codex/.env; this host must not do that.
    match std::env::args_os().nth(1).as_deref() {
        Some(arg) if arg == codex_exec_server::CODEX_ARG0_EXEC_HELPER_ARG1 => {
            codex_exec_server::run_arg0_exec_helper_main()
        }
        Some(arg) if arg == codex_exec_server::CODEX_FS_HELPER_ARG1 => {
            codex_exec_server::run_fs_helper_main()
        }
        _ => {}
    }
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_stack_size(16 * 1024 * 1024)
        .build()?;
    let result = runtime.block_on(run());
    // Tokio's stdin uses a blocking read that cannot be aborted while the client keeps
    // its pipe open. All runs and writers have already been drained by serve().
    runtime.shutdown_timeout(std::time::Duration::from_millis(250));
    result
}

async fn run() -> Result<()> {
    let args = Args::parse();
    if matches!(args.command, Action::SearchFilesSession) {
        return shipios_tools::file_search_session::serve(&args.project);
    }
    if let Action::SearchFiles { query } = &args.command {
        println!(
            "{}",
            serde_json::to_string(&shipios_tools::file_search::search(&args.project, query)?)?
        );
        return Ok(());
    }
    let data_dir = match args
        .data_dir
        .or_else(|| std::env::var_os("SHIPIOS_HOME").map(PathBuf::from))
    {
        Some(path) => {
            if path.is_absolute() {
                path
            } else {
                std::env::current_dir()?.join(path)
            }
        }
        None => {
            PathBuf::from(std::env::var_os("HOME").context("HOME is unavailable; pass --data-dir")?)
                .join("Library/Application Support/ShipiOS")
        }
    };
    let config = Config::load(
        &data_dir,
        &args.project,
        args.trust_project_config,
        Layer {
            build_timeout_seconds: args.build_timeout_seconds,
            ..Default::default()
        },
    )?;
    match args.command {
        Action::Config => println!("{}", serde_json::to_string_pretty(&config)?),
        Action::Inspect => println!(
            "{}",
            serde_json::to_string_pretty(&shipios_tools::project::inspect(&config.project)?)?
        ),
        action => {
            let service = Arc::new(service::Service::new(config)?);
            match action {
                Action::Serve => rpc::serve(service).await?,
                Action::Runs => println!("{}", serde_json::to_string_pretty(&service.list()?)?),
                action => {
                    let request = match action {
                        Action::Doctor => service::RunRequest::Doctor,
                        Action::Build {
                            container,
                            scheme,
                            configuration,
                        } => service::RunRequest::Build(BuildRequest {
                            container,
                            scheme,
                            configuration,
                        }),
                        _ => unreachable!(),
                    };
                    let mut terminate =
                        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
                    let run = service.start(request)?;
                    tokio::select! {
                        _ = service.wait_idle() => {},
                        _ = tokio::signal::ctrl_c() => { service.cancel(&run.id)?; service.wait_idle().await; }
                        _ = terminate.recv() => { service.cancel(&run.id)?; service.wait_idle().await; }
                    }
                    let result = service.get(&run.id)?;
                    println!("{}", serde_json::to_string_pretty(&result)?);
                    if result.status != shipios_core::RunStatus::Succeeded {
                        std::process::exit(1);
                    }
                }
            }
        }
    }
    Ok(())
}
