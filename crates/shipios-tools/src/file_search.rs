use anyhow::{Result, ensure};
use nucleo_matcher::{
    Config, Matcher, Utf32Str,
    pattern::{CaseMatching, Normalization, Pattern},
};
use serde::Serialize;
use std::path::Path;

const LIMIT: usize = 50;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileSearchMatch {
    pub path: String,
    pub is_directory: bool,
    pub score: u32,
    #[serde(skip)]
    length: usize,
}

/// Match paths with the same nucleo revision/configuration as the upstream file-search service.
/// The desktop applies its own filename ranking after this candidate limit.
pub fn search(root: &Path, query: &str) -> Result<Vec<FileSearchMatch>> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(Vec::new());
    }
    let root = root.canonicalize()?;
    ensure!(root.is_dir(), "Search root must be a directory");
    let pattern = Pattern::parse(query, CaseMatching::Ignore, Normalization::Smart);
    let mut matcher = Matcher::new(Config::DEFAULT.match_paths());
    let mut buffer = Vec::new();
    let mut matches = Vec::new();
    for entry in ignore::WalkBuilder::new(&root)
        .hidden(false)
        .follow_links(true)
        .require_git(true)
        .build()
    {
        let Ok(entry) = entry else { continue };
        let Ok(relative) = entry.path().strip_prefix(&root) else {
            continue;
        };
        let Some(path) = relative.to_str().filter(|path| !path.is_empty()) else {
            continue;
        };
        let haystack = Utf32Str::new(path, &mut buffer);
        let Some(score) = pattern.score(haystack, &mut matcher) else {
            continue;
        };
        matches.push(FileSearchMatch {
            path: path.to_owned(),
            is_directory: entry.file_type().is_some_and(|kind| kind.is_dir()),
            score,
            length: haystack.len(),
        });
        // Nucleo selects candidates by score, then length, then insertion order.
        matches.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.length.cmp(&b.length)));
        matches.truncate(LIMIT);
    }
    matches.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.path.cmp(&b.path)));
    Ok(matches)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn subsequence_paths_directories_hidden_files_and_case_normalization() -> Result<()> {
        let root = tempfile::tempdir()?;
        fs::create_dir(root.path().join("Sources"))?;
        fs::write(root.path().join("Sources/CommandPaletteView.swift"), "")?;
        fs::write(root.path().join(".hidden-config"), "")?;
        fs::write(root.path().join("Café.swift"), "")?;
        assert_eq!(
            search(root.path(), "CPV")?[0].path,
            "Sources/CommandPaletteView.swift"
        );
        assert!(
            search(root.path(), "srcpv")?
                .iter()
                .any(|m| m.path.ends_with("CommandPaletteView.swift"))
        );
        assert!(
            search(root.path(), "Sources")?
                .iter()
                .any(|m| m.is_directory)
        );
        assert_eq!(search(root.path(), "hidden")?[0].path, ".hidden-config");
        assert_eq!(search(root.path(), "cafe")?[0].path, "Café.swift");
        assert!(search(root.path(), "  ")?.is_empty());
        assert!(search(root.path(), "missing")?.is_empty());
        Ok(())
    }

    #[test]
    fn git_ignored_paths_are_skipped_and_candidates_are_bounded_and_sorted() -> Result<()> {
        let root = tempfile::tempdir()?;
        fs::create_dir(root.path().join(".git"))?;
        fs::write(root.path().join(".gitignore"), "ignored*\n")?;
        fs::write(root.path().join("ignored.swift"), "")?;
        for i in 0..70 {
            fs::write(root.path().join(format!("Result{i:02}.swift")), "")?;
        }
        assert!(search(root.path(), "ignored")?.is_empty());
        let results = search(root.path(), "result")?;
        assert_eq!(results.len(), LIMIT);
        assert!(
            results
                .windows(2)
                .all(|pair| pair[0].score >= pair[1].score)
        );
        assert_eq!(results[0].path, "Result00.swift");
        assert!(search(&root.path().join("absent"), "query").is_err());
        Ok(())
    }

    #[test]
    fn candidate_limit_prefers_shorter_paths_before_final_path_sort() -> Result<()> {
        let root = tempfile::tempdir()?;
        for count in (1..=70).rev() {
            fs::write(
                root.path().join(format!("x{}.swift", "a".repeat(count))),
                "",
            )?;
        }
        let results = search(root.path(), "x")?;
        assert_eq!(results.len(), LIMIT);
        assert!(results.iter().all(|item| item.path.len() <= 57));
        assert!(
            results
                .windows(2)
                .all(|pair| pair[0].score == pair[1].score)
        );
        Ok(())
    }
}
