use anyhow::{Result, ensure};
use serde_json::json;
use std::{
    collections::VecDeque,
    fs::{self, OpenOptions},
    io::Write,
    os::unix::fs::OpenOptionsExt,
    path::PathBuf,
    sync::{Arc, Mutex},
};
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    sync::broadcast,
};

pub const LOG_LIMIT: u64 = 5 * 1024 * 1024;
pub const LINE_LIMIT: usize = 8192;
pub struct Logs {
    path: PathBuf,
    limit: u64,
    lines: VecDeque<String>,
    redactor: crate::daemon::redact::Redactor,
    /// Open handle and its current size; reopened only after a rotation.
    file: std::fs::File,
    size: u64,
}
impl Logs {
    pub fn new(path: PathBuf, limit: u64) -> Result<Self> {
        let file = Self::open(&path)?;
        let size = file.metadata()?.len();
        Ok(Self {
            path,
            limit,
            lines: VecDeque::new(),
            redactor: Default::default(),
            file,
            size,
        })
    }
    fn open(path: &std::path::Path) -> Result<std::fs::File> {
        Ok(OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)?)
    }
    /// Writes one line of output with its secret values hidden (see `redact.rs`): the line stays,
    /// only the values go.
    pub fn append(&mut self, line: &str) -> Result<String> {
        let clean: String = line
            .chars()
            .take(LINE_LIMIT)
            .filter(|c| !c.is_control() || *c == '\t')
            .collect();
        let safe: String = self
            .redactor
            .line(&clean)
            .chars()
            .take(LINE_LIMIT)
            .collect();
        ensure!((safe.len() as u64) < self.limit, "log_line_too_large");
        if self.size + safe.len() as u64 + 1 > self.limit {
            for index in (1..=3).rev() {
                let previous = if index == 1 {
                    self.path.clone()
                } else {
                    self.path.with_extension(format!("log.{}", index - 1))
                };
                let next = self.path.with_extension(format!("log.{index}"));
                if previous.try_exists()? {
                    fs::rename(previous, next)?;
                }
            }
            self.file = Self::open(&self.path)?;
            self.size = self.file.metadata()?.len();
        }
        writeln!(self.file, "{safe}")?;
        self.size += safe.len() as u64 + 1;
        self.lines.push_back(safe.clone());
        while self.lines.len() > 2000 {
            self.lines.pop_front();
        }
        Ok(safe)
    }
    pub fn tail(&self, count: usize) -> Vec<String> {
        self.lines
            .iter()
            .skip(self.lines.len().saturating_sub(count.min(2000)))
            .cloned()
            .collect()
    }
}

pub async fn capture(
    reader: impl AsyncRead + Unpin,
    id: String,
    logs: Arc<Mutex<Logs>>,
    events: broadcast::Sender<serde_json::Value>,
) -> Result<()> {
    let mut reader = reader;
    let mut chunk = [0; 4096];
    let mut line = Vec::new();
    let mut truncated = false;
    // A failing log must never stop the drain: a full pipe would freeze the child process.
    let mut warned = false;
    let mut store = |line: &[u8], truncated: bool| {
        if record(&id, line, truncated, &logs, &events).is_err() && !warned {
            warned = true;
            let _ =
                events.send(json!({"event":"log","id":id,"line":"Stack: registro no disponible"}));
        }
    };
    loop {
        let size = reader.read(&mut chunk).await?;
        if size == 0 {
            if !line.is_empty() {
                store(&line, truncated);
            }
            break;
        }
        for byte in &chunk[..size] {
            if *byte == b'\n' {
                store(&line, truncated);
                line.clear();
                truncated = false;
            } else if line.len() < LINE_LIMIT {
                line.push(*byte);
            } else {
                truncated = true;
            }
        }
    }
    Ok(())
}
fn record(
    id: &str,
    bytes: &[u8],
    truncated: bool,
    logs: &Arc<Mutex<Logs>>,
    events: &broadcast::Sender<serde_json::Value>,
) -> Result<()> {
    // Discard oversized lines as a whole: never split an unknown value across records.
    let line = if truncated {
        "[truncated]".into()
    } else {
        String::from_utf8_lossy(bytes)
    };
    let safe = logs
        .lock()
        .map_err(|_| anyhow::anyhow!("log_lock"))?
        .append(&line)?;
    let _ = events.send(json!({"event":"log","id":id,"line":safe}));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn capture_keeps_draining_when_the_log_fails() {
        let temp = tempfile::tempdir().unwrap();
        let logs = Arc::new(Mutex::new(
            Logs::new(temp.path().join("demo.log"), 100).unwrap(),
        ));
        let (events, mut receiver) = broadcast::channel(16);
        // Lines over the file limit make `append` fail; the pipe must still be read to the end.
        let input = format!("{}\n{}\nok\n", "x".repeat(200), "y".repeat(200));
        capture(input.as_bytes(), "a.b".into(), logs.clone(), events)
            .await
            .unwrap();
        let mut lines = vec![];
        while let Ok(event) = receiver.try_recv() {
            lines.push(event["line"].as_str().unwrap().to_string());
        }
        assert!(lines.contains(&"ok".to_string()));
        assert!(lines.iter().any(|l| l == "Stack: registro no disponible"));
    }
    #[test]
    fn rotates_real_limit_and_bounds_tail() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("demo.log");
        let mut log = Logs::new(path.clone(), LOG_LIMIT).unwrap();
        for _ in 0..3000 {
            log.append(&"x".repeat(8192)).unwrap();
        }
        for p in [
            &path,
            &path.with_extension("log.1"),
            &path.with_extension("log.2"),
            &path.with_extension("log.3"),
        ] {
            assert!(p.exists());
            assert!(fs::metadata(p).unwrap().len() <= LOG_LIMIT);
        }
        assert!(!path.with_extension("log.4").exists());
        assert_eq!(log.tail(usize::MAX).len(), 2000);
        log.append("DB_PASSWORD=sensitive").unwrap();
        assert_eq!(log.tail(1), vec!["DB_PASSWORD=[oculto]"]);
        assert!(!fs::read_to_string(path).unwrap().contains("sensitive"));
    }
}
