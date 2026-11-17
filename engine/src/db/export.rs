//! Exports to CSV, JSON or SQL INSERTs, streamed: the engine's client prints rows as the server
//! sends them (`psql --csv`, `sqlite3 .mode csv`, `mysql --xml --quick`) and each row is written
//! to the file as soon as it is read, so a table of any size never sits in memory.
use crate::core::fsutil::private_options;
use crate::{
    db::client::{self, Target},
    db::sql::{self, Dialect},
};
use anyhow::{bail, ensure, Result};
use std::{
    io::{BufRead, BufReader, BufWriter, Read, Write},
    path::Path,
    process::{ChildStdout, Stdio},
};

const NULL_MARK: &str = "\u{1}NULL\u{1}";
/// A row of `mysql --xml`: each field with its column name.
type NamedRow = Vec<(String, Option<String>)>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Csv,
    Json,
    Sql,
}

impl Format {
    pub fn parse(text: &str) -> Result<Self> {
        Ok(match text {
            "csv" => Format::Csv,
            "json" => Format::Json,
            "sql" => Format::Sql,
            _ => bail!("invalid_request"),
        })
    }
}

/// Rows as the client prints them, one at a time.
trait Rows {
    /// Column names (known after the first row for MySQL; `fallback` when there are no rows).
    fn columns(&mut self) -> Result<Vec<String>>;
    fn next_row(&mut self) -> Result<Option<Vec<Option<String>>>>;
}

/// RFC 4180 records read from a stream (psql and sqlite3 CSV), header first.
struct CsvRows<R: BufRead> {
    input: R,
    header: Option<Vec<String>>,
}

impl<R: BufRead> CsvRows<R> {
    /// One record: each field with whether it was quoted. None at the end of the stream.
    fn record(&mut self) -> Result<Option<Vec<(String, bool)>>> {
        let mut fields = vec![];
        let mut field = Vec::new();
        let mut quoted = false;
        let mut in_quotes = false;
        let mut any = false;
        let mut byte = [0u8; 1];
        loop {
            if self.input.read(&mut byte)? == 0 {
                if !any {
                    return Ok(None);
                }
                fields.push((String::from_utf8_lossy(&field).into_owned(), quoted));
                return Ok(Some(fields));
            }
            any = true;
            let c = byte[0];
            if in_quotes {
                if c == b'"' {
                    let next = self.input.fill_buf()?.first().copied();
                    if next == Some(b'"') {
                        self.input.consume(1);
                        field.push(b'"');
                    } else {
                        in_quotes = false;
                    }
                } else {
                    field.push(c);
                }
                continue;
            }
            match c {
                b'"' if field.is_empty() => {
                    in_quotes = true;
                    quoted = true;
                }
                b',' => {
                    fields.push((
                        String::from_utf8_lossy(&std::mem::take(&mut field)).into_owned(),
                        quoted,
                    ));
                    quoted = false;
                }
                b'\r' if self.input.fill_buf()?.first() == Some(&b'\n') => {}
                b'\n' => {
                    fields.push((String::from_utf8_lossy(&field).into_owned(), quoted));
                    return Ok(Some(fields));
                }
                _ => field.push(c),
            }
        }
    }
}

impl<R: BufRead> Rows for CsvRows<R> {
    fn columns(&mut self) -> Result<Vec<String>> {
        if self.header.is_none() {
            self.header = Some(
                self.record()?
                    .unwrap_or_default()
                    .into_iter()
                    .map(|(name, _)| name)
                    .collect(),
            );
        }
        Ok(self.header.clone().unwrap_or_default())
    }
    fn next_row(&mut self) -> Result<Option<Vec<Option<String>>>> {
        self.columns()?;
        Ok(self.record()?.map(|row| {
            row.into_iter()
                .map(|(value, quoted)| (quoted || value != NULL_MARK).then_some(value))
                .collect()
        }))
    }
}

/// `<row>` elements of `mysql --xml`, cut from the stream as each one completes.
struct XmlRows<R: Read> {
    input: R,
    buffer: Vec<u8>,
    done: bool,
    names: Option<Vec<String>>,
    first: Option<Vec<Option<String>>>,
    fallback: Vec<String>,
}

impl<R: Read> XmlRows<R> {
    fn read_row(&mut self) -> Result<Option<NamedRow>> {
        loop {
            if let Some(end) = find(&self.buffer, b"</row>") {
                let segment: Vec<u8> = self.buffer.drain(..end + 6).collect();
                let text = String::from_utf8_lossy(&segment);
                let start = text.find("<row>").map(|i| i + 5).unwrap_or(0);
                let body = &text[start..text.len() - 6];
                return Ok(Some(sql::parse_mysql_row(body)));
            }
            if self.done {
                return Ok(None);
            }
            let mut chunk = vec![0u8; 256 * 1024];
            let n = self.input.read(&mut chunk)?;
            if n == 0 {
                self.done = true;
            } else {
                self.buffer.extend_from_slice(&chunk[..n]);
                // Text before the next <row> is the XML preamble or whitespace: never kept.
                if find(&self.buffer, b"<row>").is_none()
                    && self.buffer.len() > 4096
                    && find(&self.buffer, b"</row>").is_none()
                {
                    let keep = self.buffer.len() - 16;
                    self.buffer.drain(..keep);
                }
            }
        }
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

impl<R: Read> Rows for XmlRows<R> {
    fn columns(&mut self) -> Result<Vec<String>> {
        if self.names.is_none() {
            match self.read_row()? {
                Some(row) => {
                    self.names = Some(row.iter().map(|(n, _)| n.clone()).collect());
                    self.first = Some(row.into_iter().map(|(_, v)| v).collect());
                }
                None => self.names = Some(self.fallback.clone()),
            }
        }
        Ok(self.names.clone().unwrap_or_default())
    }
    fn next_row(&mut self) -> Result<Option<Vec<Option<String>>>> {
        self.columns()?;
        if let Some(first) = self.first.take() {
            return Ok(Some(first));
        }
        Ok(self
            .read_row()?
            .map(|row| row.into_iter().map(|(_, v)| v).collect()))
    }
}

/// A CSV field: quoted when it has to be, and always for an empty string (an empty unquoted
/// field is NULL).
fn csv_field(value: &Option<String>) -> String {
    match value {
        None => String::new(),
        Some(v) if v.is_empty() || v.contains([',', '"', '\n', '\r']) => {
            format!("\"{}\"", v.replace('"', "\"\""))
        }
        Some(v) => v.clone(),
    }
}

/// A portable SQL string literal. A MySQL value with a backslash is written in hex: restored on a
/// server with `NO_BACKSLASH_ESCAPES` a doubled backslash would come back as two.
fn sql_field(dialect: Dialect, value: &Option<String>) -> String {
    match value {
        None => "NULL".into(),
        Some(v) if dialect == Dialect::MySql && v.contains('\\') => {
            crate::db::sql::literal(dialect, v)
        }
        Some(v) => format!("'{}'", v.replace('\'', "''")),
    }
}

/// Writes every row of `rows` to `out` in the format; `table` names the INSERT target. Calls
/// `progress` with the rows written so far.
fn write_rows(
    rows: &mut dyn Rows,
    out: &mut dyn Write,
    format: Format,
    dialect: Dialect,
    table: &str,
    progress: &mut dyn FnMut(u64),
) -> Result<u64> {
    let columns = rows.columns()?;
    let mut count = 0u64;
    match format {
        Format::Csv => {
            out.write_all(
                columns
                    .iter()
                    .map(|c| csv_field(&Some(c.clone())))
                    .collect::<Vec<_>>()
                    .join(",")
                    .as_bytes(),
            )?;
            out.write_all(b"\n")?;
        }
        Format::Json => out.write_all(b"[")?,
        Format::Sql => {}
    }
    let names = columns
        .iter()
        .map(|c| sql::ident(dialect, c))
        .collect::<Vec<_>>()
        .join(", ");
    while let Some(row) = rows.next_row()? {
        match format {
            Format::Csv => {
                out.write_all(
                    row.iter()
                        .map(csv_field)
                        .collect::<Vec<_>>()
                        .join(",")
                        .as_bytes(),
                )?;
                out.write_all(b"\n")?;
            }
            Format::Json => {
                out.write_all(if count == 0 { b"\n  {" } else { b",\n  {" })?;
                for (i, value) in row.iter().enumerate() {
                    if i > 0 {
                        out.write_all(b", ")?;
                    }
                    let name = columns
                        .get(i)
                        .cloned()
                        .unwrap_or_else(|| format!("column{}", i + 1));
                    out.write_all(serde_json::to_string(&name)?.as_bytes())?;
                    out.write_all(b": ")?;
                    out.write_all(serde_json::to_string(value)?.as_bytes())?;
                }
                out.write_all(b"}")?;
            }
            Format::Sql => {
                let values = row
                    .iter()
                    .map(|v| sql_field(dialect, v))
                    .collect::<Vec<_>>()
                    .join(", ");
                out.write_all(
                    format!("INSERT INTO {table} ({names}) VALUES ({values});\n").as_bytes(),
                )?;
            }
        }
        count += 1;
        progress(count);
    }
    if format == Format::Json {
        out.write_all(if count == 0 { b"]\n" } else { b"\n]\n" })?;
    }
    Ok(count)
}

/// A file being written next to its destination as `<name>.partial`. The destination is only
/// replaced (by a rename) once `commit` runs; dropping the guard otherwise deletes just the
/// partial, so a failed run never truncates or removes a file the user already had.
pub(crate) struct Partial {
    partial: std::path::PathBuf,
    dest: std::path::PathBuf,
    committed: bool,
}

impl Partial {
    /// Creates the (private) partial file for `dest`; a stale partial of an earlier run is replaced.
    pub(crate) fn create(dest: &Path) -> Result<(Self, std::fs::File)> {
        let mut name = dest
            .file_name()
            .ok_or_else(|| anyhow::anyhow!("invalid_file"))?
            .to_os_string();
        name.push(".partial");
        let partial = dest.with_file_name(name);
        let _ = std::fs::remove_file(&partial);
        let file = private_options().create_new(true).open(&partial)?;
        Ok((
            Self {
                partial,
                dest: dest.to_path_buf(),
                committed: false,
            },
            file,
        ))
    }

    #[cfg(test)]
    pub(crate) fn path(&self) -> &Path {
        &self.partial
    }

    /// Moves the finished partial over the destination.
    pub(crate) fn commit(mut self) -> Result<()> {
        std::fs::rename(&self.partial, &self.dest)?;
        self.committed = true;
        Ok(())
    }
}

impl Drop for Partial {
    fn drop(&mut self) {
        if !self.committed {
            let _ = std::fs::remove_file(&self.partial);
        }
    }
}

/// Runs one read-only SELECT and streams its rows into `path`. `table` is the INSERT target
/// (already quoted); `fallback` names the columns if no row comes back (MySQL prints none then).
#[allow(clippy::too_many_arguments)]
pub fn export(
    target: &Target,
    database: &str,
    select: &str,
    format: Format,
    path: &Path,
    table: &str,
    fallback: Vec<String>,
    progress: &mut dyn FnMut(u64),
) -> Result<u64> {
    let dialect = target
        .dialect()
        .ok_or_else(|| anyhow::anyhow!("unsupported_engine"))?;
    let secret = if dialect == Dialect::MySql {
        Some(target.mysql_options()?)
    } else {
        None
    };
    let (mut command, script) = match dialect {
        Dialect::MySql => {
            let mut c = target.command("mysql", database, secret.as_ref())?;
            c.args(["--xml", "--binary-as-hex", "--quick", "--batch"]);
            (
                c,
                format!("START TRANSACTION READ ONLY;\n{select}\n;\nCOMMIT;\n"),
            )
        }
        Dialect::Postgres => {
            let mut c = target.command("psql", database, None)?;
            c.args([
                "-X",
                "-q",
                "--csv",
                "-v",
                "ON_ERROR_STOP=1",
                "-v",
                "VERBOSITY=verbose",
                "-P",
                &format!("null={NULL_MARK}"),
                "-f",
                "-",
            ]);
            // Read-only even on a writable connection: an export never changes anything.
            (
                c,
                format!("BEGIN TRANSACTION READ ONLY;\n{select}\n;\nCOMMIT;\n"),
            )
        }
        Dialect::Sqlite => {
            let c = target.command("sqlite3", database, None)?;
            (c, format!(".headers on\n.mode csv\n.nullvalue {NULL_MARK}\nPRAGMA query_only = ON;\n{select}\n;\n"))
        }
    };
    let (partial, file) = Partial::create(path)?;
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|_| anyhow::anyhow!("client_not_installed"))?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| anyhow::anyhow!("export_failed"))?;
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(script.as_bytes());
    });
    let mut errors = child
        .stderr
        .take()
        .ok_or_else(|| anyhow::anyhow!("export_failed"))?;
    let reader = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = (&mut errors).take(64 * 1024).read_to_string(&mut text);
        // Keep draining: a client that fills the pipe would block forever.
        let _ = std::io::copy(&mut errors, &mut std::io::sink());
        text
    });
    let stdout: ChildStdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow::anyhow!("export_failed"))?;
    let mut out = BufWriter::with_capacity(256 * 1024, file);
    let written = {
        let mut rows: Box<dyn Rows> = match dialect {
            Dialect::MySql => Box::new(XmlRows {
                input: stdout,
                buffer: vec![],
                done: false,
                names: None,
                first: None,
                fallback,
            }),
            _ => Box::new(CsvRows {
                input: BufReader::with_capacity(256 * 1024, stdout),
                header: None,
            }),
        };
        write_rows(rows.as_mut(), &mut out, format, dialect, table, progress)
    };
    let flushed = out.flush();
    let status = child.wait()?;
    let _ = writer.join();
    let stderr = reader.join().unwrap_or_default();
    drop(secret);
    let failed = !status.success() || (dialect == Dialect::Sqlite && !stderr.trim().is_empty());
    if failed || written.is_err() || flushed.is_err() {
        if failed {
            return Err(client::db_error(
                &client::clean_error(&stderr).unwrap_or_else(|| "export_failed".into()),
            ));
        }
        bail!("export_failed");
    }
    ensure!(written.is_ok(), "export_failed");
    partial.commit()?;
    written
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixed(Vec<String>, std::vec::IntoIter<Vec<Option<String>>>);
    impl Rows for Fixed {
        fn columns(&mut self) -> Result<Vec<String>> {
            Ok(self.0.clone())
        }
        fn next_row(&mut self) -> Result<Option<Vec<Option<String>>>> {
            Ok(self.1.next())
        }
    }

    fn sample() -> Fixed {
        Fixed(
            vec!["id".into(), "note".into()],
            vec![
                vec![Some("1".into()), None],
                vec![Some("2".into()), Some("a,\"b\"\nc".into())],
                vec![Some("3".into()), Some(String::new())],
            ]
            .into_iter(),
        )
    }

    fn render(format: Format, dialect: Dialect) -> String {
        let mut out = Vec::new();
        write_rows(
            &mut sample(),
            &mut out,
            format,
            dialect,
            "\"t\"",
            &mut |_| {},
        )
        .unwrap();
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn partial_files_replace_the_destination_only_on_commit() {
        let dir = std::env::temp_dir().join(format!("stack-partial-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let dest = dir.join("backup.sql");
        std::fs::write(&dest, "old").unwrap();
        // A failed run (guard dropped) removes only its partial and keeps the user's file.
        let (partial, mut file) = Partial::create(&dest).unwrap();
        file.write_all(b"new").unwrap();
        let partial_path = partial.path().to_path_buf();
        assert_eq!(partial_path, dir.join("backup.sql.partial"));
        assert_eq!(std::fs::read_to_string(&dest).unwrap(), "old");
        drop(partial);
        assert!(!partial_path.exists());
        assert_eq!(std::fs::read_to_string(&dest).unwrap(), "old");
        // A finished run renames the partial over the destination.
        let (partial, mut file) = Partial::create(&dest).unwrap();
        file.write_all(b"new").unwrap();
        partial.commit().unwrap();
        assert_eq!(std::fs::read_to_string(&dest).unwrap(), "new");
        assert!(!partial_path.exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn formats_keep_nulls_apart_from_empty_strings() {
        assert_eq!(
            render(Format::Csv, Dialect::Postgres),
            "id,note\n1,\n2,\"a,\"\"b\"\"\nc\"\n3,\"\"\n"
        );
        let json: serde_json::Value =
            serde_json::from_str(&render(Format::Json, Dialect::Postgres)).unwrap();
        assert_eq!(json[0]["note"], serde_json::Value::Null);
        assert_eq!(json[2]["note"], "");
        assert_eq!(json[1]["note"], "a,\"b\"\nc");
        let sql = render(Format::Sql, Dialect::MySql);
        assert!(sql.starts_with("INSERT INTO \"t\" (`id`, `note`) VALUES ('1', NULL);\n"));
        assert!(sql.contains("VALUES ('3', '');"));
        let mut out = Vec::new();
        write_rows(
            &mut Fixed(vec!["x".into()], vec![].into_iter()),
            &mut out,
            Format::Json,
            Dialect::Sqlite,
            "x",
            &mut |_| {},
        )
        .unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "[]\n");
    }

    #[test]
    fn streams_are_cut_into_rows() {
        let csv = format!("id,name\n1,{NULL_MARK}\n2,\"l1\nl2\"\n3,\"\"\n");
        let mut rows = CsvRows {
            input: BufReader::with_capacity(3, csv.as_bytes()),
            header: None,
        };
        assert_eq!(rows.columns().unwrap(), vec!["id", "name"]);
        assert_eq!(rows.next_row().unwrap(), Some(vec![Some("1".into()), None]));
        assert_eq!(
            rows.next_row().unwrap(),
            Some(vec![Some("2".into()), Some("l1\nl2".into())])
        );
        assert_eq!(
            rows.next_row().unwrap(),
            Some(vec![Some("3".into()), Some(String::new())])
        );
        assert_eq!(rows.next_row().unwrap(), None);
        let xml = "<?xml version=\"1.0\"?>\n<resultset statement=\"select\" xmlns:xsi=\"x\">\n  <row>\n\t<field name=\"id\">1</field>\n\t<field name=\"n\" xsi:nil=\"true\" />\n  </row>\n  <row>\n\t<field name=\"id\">2</field>\n\t<field name=\"n\">&lt;ñ&gt;</field>\n  </row>\n</resultset>\n";
        let mut rows = XmlRows {
            input: xml.as_bytes(),
            buffer: vec![],
            done: false,
            names: None,
            first: None,
            fallback: vec![],
        };
        assert_eq!(rows.columns().unwrap(), vec!["id", "n"]);
        assert_eq!(rows.next_row().unwrap(), Some(vec![Some("1".into()), None]));
        assert_eq!(
            rows.next_row().unwrap(),
            Some(vec![Some("2".into()), Some("<ñ>".into())])
        );
        assert_eq!(rows.next_row().unwrap(), None);
        let empty = "<?xml version=\"1.0\"?>\n<resultset statement=\"select\" xmlns:xsi=\"x\">\n</resultset>\n";
        let mut rows = XmlRows {
            input: empty.as_bytes(),
            buffer: vec![],
            done: false,
            names: None,
            first: None,
            fallback: vec!["a".into()],
        };
        assert_eq!(rows.columns().unwrap(), vec!["a"]);
        assert_eq!(rows.next_row().unwrap(), None);
    }
}
