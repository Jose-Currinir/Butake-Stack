//! Receiver of `dump()` calls: the VarDumper server protocol (`php artisan dump-server`,
//! `var-dump-server`) on 127.0.0.1. Each line a client sends is
//! `base64(serialize([Data $data, array $context]))`. The payload is parsed here as plain data
//! (a PHP `unserialize` reader that never instantiates anything) and turned into text like the
//! CLI dumper's. Dumps live in the daemon's memory only (the newest 300).
use crate::core::codec;
use serde_json::{json, Value};
use std::{
    collections::{HashSet, VecDeque},
    sync::Mutex,
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, BufReader},
    net::TcpListener,
};

const MAX_PAYLOAD: u64 = 16 * 1024 * 1024;
const MAX_DUMPS: usize = 300;
const MAX_RETAINED_BYTES: usize = 8 * 1024 * 1024;
const MAX_LINES: usize = 3000;
const MAX_DEPTH: usize = 25;

struct DumpBuffer {
    items: VecDeque<(Value, usize)>,
    bytes: usize,
}
static DUMPS: Mutex<DumpBuffer> = Mutex::new(DumpBuffer {
    items: VecDeque::new(),
    bytes: 0,
});
static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

// ---- PHP serialize reader ----

#[derive(Debug, Clone, PartialEq)]
pub enum Key {
    Int(i64),
    Str(Vec<u8>),
}

#[derive(Debug, Clone)]
pub enum Node {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(Vec<u8>),
    Array(Vec<(Key, usize)>),
    Object(String, Vec<(Key, usize)>),
    /// `r:`/`R:`: another value of the payload (by its node).
    Ref(usize),
}

pub struct Parsed {
    pub nodes: Vec<Node>,
    pub root: usize,
}

struct Reader<'a> {
    data: &'a [u8],
    at: usize,
    nodes: Vec<Node>,
    /// PHP's numbering of values for `r:`/`R:` (1-based), pointing at nodes.
    slots: Vec<usize>,
    depth: usize,
}

impl Reader<'_> {
    fn byte(&mut self) -> Option<u8> {
        let b = *self.data.get(self.at)?;
        self.at += 1;
        Some(b)
    }
    fn expect(&mut self, b: u8) -> Option<()> {
        (self.byte()? == b).then_some(())
    }
    fn until(&mut self, end: u8) -> Option<&[u8]> {
        let start = self.at;
        let length = self.data[start..].iter().position(|&c| c == end)?;
        self.at = start + length + 1;
        Some(&self.data[start..start + length])
    }
    fn number<T: std::str::FromStr>(&mut self, end: u8) -> Option<T> {
        std::str::from_utf8(self.until(end)?).ok()?.parse().ok()
    }
    fn string(&mut self) -> Option<Vec<u8>> {
        let length: usize = self.number(b':')?;
        self.expect(b'"')?;
        let bytes = self
            .data
            .get(self.at..self.at.checked_add(length)?)?
            .to_vec();
        self.at += length;
        self.expect(b'"')?;
        Some(bytes)
    }
    fn key(&mut self) -> Option<Key> {
        match self.byte()? {
            b'i' => {
                self.expect(b':')?;
                Some(Key::Int(self.number(b';')?))
            }
            b's' => {
                self.expect(b':')?;
                let s = self.string()?;
                self.expect(b';')?;
                Some(Key::Str(s))
            }
            _ => None,
        }
    }
    fn push(&mut self, node: Node) -> usize {
        self.nodes.push(node);
        self.nodes.len() - 1
    }
    fn entries(&mut self, count: usize) -> Option<Vec<(Key, usize)>> {
        self.expect(b'{')?;
        let mut entries = Vec::with_capacity(count.min(4096));
        for _ in 0..count {
            let key = self.key()?;
            entries.push((key, self.value()?));
        }
        self.expect(b'}')?;
        Some(entries)
    }
    fn value(&mut self) -> Option<usize> {
        self.depth += 1;
        if self.depth > 512 || self.nodes.len() > 2_000_000 {
            return None;
        }
        let kind = self.byte()?;
        // Every value takes a number except `R:` (PHP's var_push rule).
        let index = self.push(Node::Null);
        if kind != b'R' {
            self.slots.push(index);
        }
        let node = match kind {
            b'N' => {
                self.expect(b';')?;
                Node::Null
            }
            b'b' => {
                self.expect(b':')?;
                Node::Bool(self.number::<u8>(b';')? != 0)
            }
            b'i' => {
                self.expect(b':')?;
                Node::Int(self.number(b';')?)
            }
            b'd' => {
                self.expect(b':')?;
                let text = String::from_utf8_lossy(self.until(b';')?).into_owned();
                Node::Float(match text.as_str() {
                    "INF" => f64::INFINITY,
                    "-INF" => f64::NEG_INFINITY,
                    "NAN" => f64::NAN,
                    t => t.parse().ok()?,
                })
            }
            b's' => {
                self.expect(b':')?;
                let s = self.string()?;
                self.expect(b';')?;
                Node::Str(s)
            }
            b'r' | b'R' => {
                self.expect(b':')?;
                let slot: usize = self.number(b';')?;
                Node::Ref(*self.slots.get(slot.checked_sub(1)?)?)
            }
            b'a' => {
                self.expect(b':')?;
                let count = self.number(b':')?;
                Node::Array(self.entries(count)?)
            }
            b'O' => {
                self.expect(b':')?;
                let class = String::from_utf8_lossy(&self.string()?).into_owned();
                self.expect(b':')?;
                let count = self.number(b':')?;
                Node::Object(class, self.entries(count)?)
            }
            b'C' => {
                // Custom serialization: kept as its raw text.
                self.expect(b':')?;
                let class = String::from_utf8_lossy(&self.string()?).into_owned();
                self.expect(b':')?;
                let length: usize = self.number(b':')?;
                self.expect(b'{')?;
                let raw = self
                    .data
                    .get(self.at..self.at.checked_add(length)?)?
                    .to_vec();
                self.at += length;
                self.expect(b'}')?;
                Node::Str([class.into_bytes(), b" ".to_vec(), raw].concat())
            }
            b'E' => {
                self.expect(b':')?;
                let s = self.string()?;
                self.expect(b';')?;
                Node::Str(s)
            }
            _ => return None,
        };
        self.nodes[index] = node;
        self.depth -= 1;
        Some(index)
    }
}

pub fn unserialize(data: &[u8]) -> Option<Parsed> {
    let mut reader = Reader {
        data,
        at: 0,
        nodes: vec![],
        slots: vec![],
        depth: 0,
    };
    let root = reader.value()?;
    Some(Parsed {
        nodes: reader.nodes,
        root,
    })
}

// ---- Rendering of a VarDumper Data clone ----

fn key_text(key: &Key) -> String {
    match key {
        Key::Int(i) => i.to_string(),
        Key::Str(s) => String::from_utf8_lossy(s).into_owned(),
    }
}

/// Property name without PHP's visibility prefix, plus the dumper's marker.
fn property(key: &Key) -> String {
    let Key::Str(raw) = key else {
        return format!("+{}", key_text(key));
    };
    if raw.first() == Some(&0) {
        if let Some(end) = raw[1..].iter().position(|&b| b == 0) {
            let scope = &raw[1..1 + end];
            let name = String::from_utf8_lossy(&raw[end + 2..]);
            return match scope {
                b"*" => format!("#{name}"),
                b"+" => format!("+{name}"),
                b"~" => format!("~{name}"),
                _ => format!("-{name}"),
            };
        }
    }
    format!("+{}", String::from_utf8_lossy(raw))
}

fn quote(bytes: &[u8], binary: bool) -> String {
    if binary {
        let escaped: String = bytes
            .iter()
            .take(2000)
            .map(|&b| match b {
                b'"' => "\\\"".into(),
                0x20..=0x7e => (b as char).to_string(),
                _ => format!("\\x{b:02X}"),
            })
            .collect();
        return format!("b\"{escaped}\"");
    }
    let text = String::from_utf8_lossy(bytes);
    let escaped: String = text
        .chars()
        .take(2000)
        .map(|c| match c {
            '"' => "\\\"".into(),
            '\n' => "\\n".into(),
            '\r' => "\\r".into(),
            '\t' => "\\t".into(),
            c if c.is_control() => format!("\\x{:02X}", c as u32),
            c => c.to_string(),
        })
        .collect();
    format!("{}\"{escaped}\"", if binary { "b" } else { "" })
}

struct Stub {
    kind: i64,
    class: Option<usize>,
    value: Option<usize>,
    cut: i64,
    handle: i64,
    ref_count: i64,
    position: i64,
    attr: Option<usize>,
}

struct Render<'a> {
    nodes: &'a [Node],
    /// `$data` of the clone: one children list per position.
    data: Vec<usize>,
    lines: Vec<String>,
    seen: HashSet<i64>,
}

impl Render<'_> {
    fn resolve(&self, mut index: usize) -> usize {
        for _ in 0..16 {
            match self.nodes.get(index) {
                Some(Node::Ref(target)) => index = *target,
                _ => break,
            }
        }
        index
    }
    fn node(&self, index: usize) -> &Node {
        &self.nodes[self.resolve(index)]
    }
    fn int(&self, index: Option<usize>) -> i64 {
        match index.map(|i| self.node(i)) {
            Some(Node::Int(i)) => *i,
            Some(Node::Bool(b)) => *b as i64,
            _ => 0,
        }
    }
    fn entries(&self, index: usize) -> &[(Key, usize)] {
        match self.node(index) {
            Node::Array(entries) | Node::Object(_, entries) => entries,
            _ => &[],
        }
    }
    fn field(&self, entries: &[(Key, usize)], name: &str) -> Option<usize> {
        entries
            .iter()
            .find(|(k, _)| property(k).trim_start_matches(['+', '-', '#']) == name)
            .map(|(_, v)| *v)
    }
    fn stub(&self, index: usize) -> Option<Stub> {
        let Node::Object(class, entries) = self.node(index) else {
            return None;
        };
        let field = |name| self.field(entries, name);
        let has_type = field("type");
        // Anything but a VarDumper stub is not expanded.
        if has_type.is_none() && !class.ends_with("Stub") {
            return None;
        }
        let mut stub = Stub {
            kind: if has_type.is_some() {
                self.int(has_type)
            } else {
                1
            },
            class: field("class"),
            value: field("value"),
            cut: self.int(field("cut")),
            handle: self.int(field("handle")),
            ref_count: self.int(field("refCount")),
            position: self.int(field("position")),
            attr: field("attr"),
        };
        // Same shape as the compact array form: handle = array kind, ref_count = count.
        if stub.kind == 3 {
            stub.handle = self.int(stub.class);
            stub.ref_count = self.int(stub.value);
        }
        Some(stub)
    }
    /// An array item stands for a compact array stub: `[class => position]`, `[0 => cut]`.
    fn array_stub(&self, entries: &[(Key, usize)]) -> Stub {
        let (class, position) = entries
            .last()
            .map(|(k, v)| {
                (
                    match k {
                        Key::Int(i) => *i,
                        _ => 0,
                    },
                    self.int(Some(*v)),
                )
            })
            .unwrap_or((0, 0));
        let cut = entries
            .iter()
            .find(|(k, _)| *k == Key::Int(0))
            .map(|(_, v)| self.int(Some(*v)))
            .unwrap_or(0);
        let count = cut
            + self
                .data
                .get(position as usize)
                .map(|i| self.entries(*i).len() as i64)
                .unwrap_or(0);
        Stub {
            kind: 3,
            class: None,
            value: None,
            cut,
            handle: class,
            ref_count: count,
            position,
            attr: None,
        }
    }
    fn text(&self, index: Option<usize>) -> String {
        match index.map(|i| self.node(i)) {
            Some(Node::Str(s)) => String::from_utf8_lossy(s).into_owned(),
            Some(Node::Int(i)) => i.to_string(),
            _ => String::new(),
        }
    }
    fn scalar(&self, index: usize) -> Option<String> {
        Some(match self.node(index) {
            Node::Null => "null".into(),
            Node::Bool(b) => b.to_string(),
            Node::Int(i) => i.to_string(),
            Node::Float(f) if f.is_finite() && f.fract() == 0.0 && f.abs() < 1e15 => {
                format!("{f:.1}")
            }
            Node::Float(f) => f.to_string().replace("inf", "INF").replace("NaN", "NAN"),
            Node::Str(s) => quote(s, false),
            _ => return None,
        })
    }
    fn emit(&mut self, depth: usize, text: String) {
        if self.lines.len() < MAX_LINES {
            self.lines.push(format!("{}{text}", "  ".repeat(depth)));
        } else if self.lines.len() == MAX_LINES {
            self.lines.push("…".into());
        }
    }
    fn item(&mut self, depth: usize, prefix: String, index: usize) {
        let index = self.resolve(index);
        if let Some(text) = self.scalar(index) {
            return self.emit(depth, format!("{prefix}{text}"));
        }
        let stub = match self.node(index).clone() {
            Node::Array(entries) if entries.is_empty() => {
                return self.emit(depth, format!("{prefix}[]"))
            }
            Node::Array(entries) => self.array_stub(&entries),
            Node::Object(..) => match self.stub(index) {
                Some(stub) => stub,
                None => {
                    let class = match self.node(index) {
                        Node::Object(class, _) => class.clone(),
                        _ => String::new(),
                    };
                    return self.emit(depth, format!("{prefix}{class} {{…}}"));
                }
            },
            _ => return self.emit(depth, format!("{prefix}?")),
        };
        // A hard reference wraps the referenced item.
        if stub.kind == 1 {
            match stub.value {
                Some(value) => return self.item(depth, format!("{prefix}&"), value),
                None => return self.emit(depth, format!("{prefix}null")),
            }
        }
        let first = stub.ref_count == 0 || stub.kind == 3 || self.seen.insert(stub.handle);
        let children: Vec<(Key, usize)> = if stub.position > 0 && first && depth < MAX_DEPTH {
            self.data
                .get(stub.position as usize)
                .map(|i| self.entries(*i).to_vec())
                .unwrap_or_default()
        } else {
            vec![]
        };
        let more = |cut: i64| {
            if cut > 0 {
                format!(" …{cut}")
            } else {
                String::new()
            }
        };
        match stub.kind {
            2 => {
                let value = match stub.value.map(|v| self.node(v)) {
                    Some(Node::Str(s)) => s.clone(),
                    _ => vec![],
                };
                let binary = self.int(stub.class) == 1;
                self.emit(
                    depth,
                    format!("{prefix}{}{}", quote(&value, binary), more(stub.cut)),
                )
            }
            3 => {
                // Compact form: handle holds the array kind (1 assoc, 2 indexed), ref_count the count.
                let assoc = stub.handle == 1;
                if children.is_empty() {
                    return self.emit(
                        depth,
                        format!(
                            "{prefix}array:{} [{}]",
                            stub.ref_count,
                            if stub.ref_count > 0 { " …" } else { "" }
                        ),
                    );
                }
                self.emit(depth, format!("{prefix}array:{} [", stub.ref_count));
                for (key, child) in &children {
                    let label = match key {
                        Key::Str(_) if assoc => {
                            format!("{} => ", quote(key_text(key).as_bytes(), false))
                        }
                        _ => format!("{} => ", key_text(key)),
                    };
                    self.item(depth + 1, label, *child);
                }
                if stub.cut > 0 {
                    self.emit(depth + 1, format!("…{}", stub.cut));
                }
                self.emit(depth, "]".into());
            }
            4 | 5 => {
                let class = self.text(stub.class);
                let head = if stub.kind == 4 {
                    format!("{class} {{#{}", stub.handle)
                } else {
                    format!("{class} resource {{@{}", stub.handle)
                };
                if children.is_empty() {
                    let ellipsis = if stub.position > 0 || stub.cut > 0 {
                        " …"
                    } else {
                        ""
                    };
                    return self.emit(depth, format!("{prefix}{head}{ellipsis}}}"));
                }
                self.emit(depth, format!("{prefix}{head}"));
                for (key, child) in &children {
                    let label = if stub.kind == 4 {
                        format!("{}: ", property(key))
                    } else {
                        format!("{}: ", key_text(key))
                    };
                    self.item(depth + 1, label, *child);
                }
                if stub.cut > 0 {
                    self.emit(depth + 1, format!("…{}", stub.cut));
                }
                self.emit(depth, "}".into());
            }
            6 => {
                let value = stub.attr.and_then(|a| self.field(self.entries(a), "value"));
                let text = value.and_then(|v| self.scalar(v)).unwrap_or_default();
                self.emit(depth, format!("{prefix}{text}"))
            }
            _ => self.emit(depth, format!("{prefix}?")),
        }
    }
}

/// Text of a `Data` clone, line by line, like the CLI dumper.
pub fn render(parsed: &Parsed, data_object: usize) -> Vec<String> {
    let nodes = &parsed.nodes;
    let mut render = Render {
        nodes,
        data: vec![],
        lines: vec![],
        seen: HashSet::new(),
    };
    let entries = render.entries(data_object).to_vec();
    let Some(data) = render.field(&entries, "data") else {
        return vec!["?".into()];
    };
    render.data = render.entries(data).iter().map(|(_, v)| *v).collect();
    let position = render.int(render.field(&entries, "position")) as usize;
    let key = render
        .field(&entries, "key")
        .map(|k| render.node(k).clone());
    let Some(children) = render.data.get(position).copied() else {
        return vec!["?".into()];
    };
    let wanted = match key {
        Some(Node::Str(s)) => Key::Str(s),
        Some(Node::Int(i)) => Key::Int(i),
        _ => Key::Int(0),
    };
    let item = render
        .entries(children)
        .iter()
        .find(|(k, _)| *k == wanted)
        .map(|(_, v)| *v);
    match item {
        Some(item) => render.item(0, String::new(), item),
        None => render.emit(0, "null".into()),
    }
    render.lines
}

/// One payload line → the dump as the app shows it.
pub fn decode(line: &str) -> Option<Value> {
    let bytes = codec::base64_decode(line.trim())?;
    let parsed = unserialize(&bytes)?;
    let render = Render {
        nodes: &parsed.nodes,
        data: vec![],
        lines: vec![],
        seen: HashSet::new(),
    };
    let top = render.entries(parsed.root).to_vec();
    let data = top
        .iter()
        .find(|(k, _)| *k == Key::Int(0))
        .map(|(_, v)| render.resolve(*v))?;
    let context = top.iter().find(|(k, _)| *k == Key::Int(1)).map(|(_, v)| *v);
    let lines = self::render(&parsed, data);
    let field = |entries: &[(Key, usize)], name: &str| render.field(entries, name);
    let mut out = json!({"lines": lines});
    if let Some(context) = context {
        let context = render.entries(context).to_vec();
        if let Some(Node::Float(time)) =
            field(&context, "timestamp").map(|t| render.node(t).clone())
        {
            out["time"] = json!(time);
        }
        if let Some(source) = field(&context, "source") {
            let source = render.entries(source).to_vec();
            out["source"] = json!({
                "name": render.text(field(&source, "name")),
                "file": render.text(field(&source, "file")),
                "line": render.int(field(&source, "line")),
            });
        }
        if let Some(request) = field(&context, "request") {
            let request = render.entries(request).to_vec();
            out["origin"] = json!(format!(
                "{} {}",
                render.text(field(&request, "method")),
                render.text(field(&request, "uri"))
            )
            .trim()
            .to_string());
        } else if let Some(cli) = field(&context, "cli") {
            out["origin"] = json!(render.text(field(render.entries(cli), "command_line")));
        }
    }
    Some(out)
}

fn keep(mut dump: Value) {
    let Ok(mut dumps) = DUMPS.lock() else { return };
    let id = SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    dump["id"] = json!(id);
    let mut size = dump.to_string().len();
    if size > MAX_RETAINED_BYTES {
        dump = json!({"id":id,"lines":["(dump demasiado grande)"]});
        size = dump.to_string().len();
    }
    dumps.items.push_back((dump, size));
    dumps.bytes += size;
    while dumps.items.len() > MAX_DUMPS || dumps.bytes > MAX_RETAINED_BYTES {
        if let Some((_, size)) = dumps.items.pop_front() {
            dumps.bytes -= size;
        }
    }
}

/// Dumps newer than `after` (an id), oldest first.
pub fn list(after: u64) -> Vec<Value> {
    DUMPS
        .lock()
        .map(|d| {
            d.items
                .iter()
                .map(|(value, _)| value)
                .filter(|v| v["id"].as_u64().unwrap_or(0) > after)
                .cloned()
                .collect()
        })
        .unwrap_or_default()
}

pub fn latest_id() -> u64 {
    DUMPS
        .lock()
        .ok()
        .and_then(|dumps| dumps.items.back()?.0.get("id")?.as_u64())
        .unwrap_or(0)
}

pub fn clear() {
    if let Ok(mut dumps) = DUMPS.lock() {
        dumps.items.clear();
        dumps.bytes = 0;
    }
}

pub async fn serve(listener: TcpListener, events: tokio::sync::broadcast::Sender<Value>) {
    // Dropping the listener task also closes established connections to the receiver.
    let mut connections = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            _ = connections.join_next(), if !connections.is_empty() => {}
            accepted = listener.accept() => {
                let Ok((stream, peer)) = accepted else { return };
                if peer.ip().is_loopback() && connections.len() < 32 {
                    connections.spawn(receive(stream, events.clone()));
                }
            }
        }
    }
}

async fn receive(stream: tokio::net::TcpStream, events: tokio::sync::broadcast::Sender<Value>) {
    let mut reader = BufReader::new(stream);
    let mut line = Vec::new();
    loop {
        line.clear();
        // A client keeps its connection open between dumps; idle ones are closed.
        let read = tokio::time::timeout(
            Duration::from_secs(3600),
            (&mut reader).take(MAX_PAYLOAD).read_until(b'\n', &mut line),
        )
        .await;
        let Ok(Ok(count)) = read else { return };
        if count == 0 || line.last() != Some(&b'\n') {
            return;
        }
        let text = String::from_utf8_lossy(&line).into_owned();
        let dump = tokio::task::spawn_blocking(move || decode(&text))
            .await
            .ok()
            .flatten();
        keep(dump.unwrap_or_else(|| json!({"lines": ["(no se pudo leer este dump)"]})));
        let _ = events.send(json!({"event":"dumps.changed"}));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_real_vardumper_payload() {
        let payload = include_str!("../../../tests/fixtures/vardumper-payload.txt");
        let dump = decode(payload).unwrap();
        let text = dump["lines"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l.as_str().unwrap())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(text.starts_with("array:7 ["), "{text}");
        assert!(text.contains("\"usuario\" => Usuario {#2"), "{text}");
        assert!(text.contains("+nombre: \"José\""), "{text}");
        assert!(
            text.contains("#edad: 40") && text.contains("-clave: \"x\""),
            "{text}"
        );
        assert!(
            text.contains("+yo: Usuario {#2 …}"),
            "a self reference is not expanded again: {text}"
        );
        assert!(
            text.contains("\"n\" => 1.5")
                && text.contains("\"ok\" => true")
                && text.contains("\"nada\" => null"),
            "{text}"
        );
        assert!(
            text.contains("\"bin\" => b\"\\xFF\\xFE\"")
                && text.contains("3 => array:3 [")
                && text.contains("\"vacío\" => []"),
            "{text}"
        );
        assert_eq!(dump["source"]["line"], 12);
        assert_eq!(dump["origin"], "artisan tinker");
        assert_eq!(dump["time"], 1731400000.25);
    }

    #[test]
    fn rejects_garbage_without_panicking() {
        for bad in [
            "",
            "%%%",
            &codec::base64_encode(b"a:9999999999:{"),
            &codec::base64_encode(b"r:99;"),
            &codec::base64_encode(b"s:99:\"x\";"),
        ] {
            assert!(decode(bad).is_none());
        }
        let nested = "a:1:{i:0;".repeat(600);
        assert!(unserialize(nested.as_bytes()).is_none());
    }
}
