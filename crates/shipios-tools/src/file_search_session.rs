use anyhow::{Result, ensure};
use nucleo::{
    Config, Nucleo, Utf32String,
    pattern::{CaseMatching, Normalization},
};
use serde::{Deserialize, Serialize};
use std::{
    io::{BufRead, Read, Write},
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::Duration,
};

#[derive(Deserialize)]
struct Query {
    id: u64,
    query: String,
}
enum Input {
    Query(Query),
    Scanned,
    Stop,
}
struct Entry {
    path: String,
    is_directory: bool,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Match {
    path: String,
    is_directory: bool,
    score: u32,
}
#[derive(Serialize)]
struct Update {
    id: u64,
    files: Vec<Match>,
    complete: bool,
}

/// One read-only index per open search surface. EOF stops the walker and matcher.
pub fn serve(root: &Path) -> Result<()> {
    let root = root.canonicalize()?;
    ensure!(root.is_dir(), "Search root must be a directory");
    let (sender, receiver) = mpsc::channel();
    let reader_sender = sender.clone();
    std::thread::spawn(move || {
        let input = std::io::stdin();
        let mut input = input.lock();
        loop {
            let mut line = Vec::new();
            // A malformed or oversized private-protocol frame closes the session.
            let read = std::io::Read::by_ref(&mut input)
                .take(65_537)
                .read_until(b'\n', &mut line);
            if !matches!(read, Ok(1..=65_536)) {
                break;
            }
            let Ok(query) = serde_json::from_slice::<Query>(&line) else {
                break;
            };
            if reader_sender.send(Input::Query(query)).is_err() {
                return;
            }
        }
        let _ = reader_sender.send(Input::Stop);
    });
    let cancelled = Arc::new(AtomicBool::new(false));
    struct CancelOnDrop(Arc<AtomicBool>);
    impl Drop for CancelOnDrop {
        fn drop(&mut self) {
            self.0.store(true, Ordering::Relaxed);
        }
    }
    let _cancel_on_drop = CancelOnDrop(cancelled.clone());
    let engine = Nucleo::<Entry>::new(Config::DEFAULT.match_paths(), Arc::new(|| {}), Some(2), 1);
    let injector = engine.injector();
    std::thread::spawn(move || {
        for entry in ignore::WalkBuilder::new(&root)
            .hidden(false)
            .follow_links(true)
            .require_git(true)
            .build()
        {
            if cancelled.load(Ordering::Relaxed) {
                break;
            }
            let Ok(entry) = entry else { continue };
            let Ok(path) = entry.path().strip_prefix(&root) else {
                continue;
            };
            let Some(path) = path.to_str().filter(|p| !p.is_empty()) else {
                continue;
            };
            injector.push(
                Entry {
                    path: path.to_owned(),
                    is_directory: entry.file_type().is_some_and(|kind| kind.is_dir()),
                },
                |entry, cols| cols[0] = Utf32String::from(entry.path.as_str()),
            );
        }
        let _ = sender.send(Input::Scanned);
    });
    run(engine, receiver, &mut std::io::stdout().lock())
}

fn run(
    mut engine: Nucleo<Entry>,
    receiver: mpsc::Receiver<Input>,
    output: &mut impl Write,
) -> Result<()> {
    let mut active: Option<Query> = None;
    let mut scanned = false;
    let mut published_complete = false;
    loop {
        let input = if published_complete && scanned {
            receiver
                .recv()
                .map_err(|_| mpsc::RecvTimeoutError::Disconnected)
        } else {
            receiver.recv_timeout(Duration::from_millis(20))
        };
        if matches!(input, Err(mpsc::RecvTimeoutError::Disconnected)) {
            return Ok(());
        }
        let mut latest = None;
        for input in input.ok().into_iter().chain(receiver.try_iter()) {
            match input {
                Input::Stop => return Ok(()),
                Input::Scanned => scanned = true,
                Input::Query(query) => latest = Some(query),
            }
        }
        if let Some(mut query) = latest {
            query.query = query.query.trim().to_owned();
            let append = active
                .as_ref()
                .is_some_and(|old| query.query.starts_with(&old.query));
            engine.pattern.reparse(
                0,
                &query.query,
                CaseMatching::Ignore,
                Normalization::Smart,
                append,
            );
            active = Some(query);
            published_complete = false;
        }
        let Some(query) = active.as_ref() else {
            continue;
        };
        if query.query.is_empty() {
            if !published_complete {
                publish(
                    output,
                    Update {
                        id: query.id,
                        files: vec![],
                        complete: true,
                    },
                )?;
            }
            published_complete = true;
            continue;
        }
        let status = engine.tick(10);
        let complete = scanned && !status.running;
        if !published_complete && (status.changed || complete) {
            let snapshot = engine.snapshot();
            let mut files: Vec<_> = snapshot
                .matches()
                .iter()
                .take(50)
                .filter_map(|matched| {
                    let item = snapshot.get_item(matched.idx)?;
                    Some(Match {
                        path: item.data.path.clone(),
                        is_directory: item.data.is_directory,
                        score: matched.score,
                    })
                })
                .collect();
            files.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.path.cmp(&b.path)));
            publish(
                output,
                Update {
                    id: query.id,
                    files,
                    complete,
                },
            )?;
        }
        published_complete = complete;
    }
}

fn publish(output: &mut impl Write, update: Update) -> Result<()> {
    serde_json::to_writer(&mut *output, &update)?;
    output.write_all(b"\n")?;
    output.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Capture {
        bytes: Vec<u8>,
        sender: mpsc::Sender<serde_json::Value>,
    }
    impl Write for Capture {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.bytes.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            self.sender
                .send(serde_json::from_slice(&self.bytes).unwrap())
                .unwrap();
            self.bytes.clear();
            Ok(())
        }
    }
    #[test]
    fn publishes_partial_results_then_completion_and_reuses_index_for_next_query() {
        let engine =
            Nucleo::<Entry>::new(Config::DEFAULT.match_paths(), Arc::new(|| {}), Some(1), 1);
        let injector = engine.injector();
        let (commands, receiver) = mpsc::channel();
        let (output, updates) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            run(
                engine,
                receiver,
                &mut Capture {
                    bytes: vec![],
                    sender: output,
                },
            )
        });
        let add = |path: &str| {
            injector.push(
                Entry {
                    path: path.into(),
                    is_directory: false,
                },
                |entry, cols| cols[0] = Utf32String::from(entry.path.as_str()),
            );
        };
        add("AlphaBeta.swift");
        commands
            .send(Input::Query(Query {
                id: 1,
                query: "ab".into(),
            }))
            .unwrap();
        loop {
            let update = updates.recv_timeout(Duration::from_secs(5)).unwrap();
            if !update["files"].as_array().unwrap().is_empty() {
                assert_eq!(update["complete"], false);
                break;
            }
        }
        add("AlphaBravo.swift");
        commands.send(Input::Scanned).unwrap();
        loop {
            let update = updates.recv_timeout(Duration::from_secs(5)).unwrap();
            if update["complete"] == true {
                assert_eq!(update["files"].as_array().unwrap().len(), 2);
                break;
            }
        }
        commands
            .send(Input::Query(Query {
                id: 2,
                query: "bravo".into(),
            }))
            .unwrap();
        loop {
            let update = updates.recv_timeout(Duration::from_secs(5)).unwrap();
            if update["id"] == 2 && update["complete"] == true {
                assert_eq!(update["files"][0]["path"], "AlphaBravo.swift");
                break;
            }
        }
        commands.send(Input::Stop).unwrap();
        worker.join().unwrap().unwrap();
    }
}
