use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Side {
    pub exists: bool,
    pub kind: String,
    pub mode: String,
    pub size: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oid: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lines: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub endofline: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fileformat: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bom: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl Side {
    pub fn limited(reason: &str, mode: &str, size: u64) -> Self {
        Self {
            exists: true,
            kind: "limited".into(),
            mode: mode.into(),
            size,
            oid: None,
            lines: None,
            endofline: None,
            fileformat: None,
            bom: None,
            content_id: None,
            reason: Some(reason.into()),
        }
    }

    pub fn missing() -> Self {
        Self {
            exists: false,
            kind: "missing".into(),
            mode: "000000".into(),
            size: 0,
            oid: None,
            lines: Some(vec![String::new()]),
            endofline: Some(false),
            fileformat: None,
            bom: None,
            content_id: None,
            reason: None,
        }
    }

    pub fn decode(raw: &[u8], mode: &str, limit: usize) -> Self {
        let size = raw.len() as u64;
        if raw.len() > limit {
            return Self::limited("too-large", mode, size);
        }
        if raw.contains(&0) {
            return Self::limited("binary", mode, size);
        }
        let Ok(text) = std::str::from_utf8(raw) else {
            return Self::limited("encoding", mode, size);
        };
        let bom = mode != "120000" && text.starts_with('\u{feff}');
        let text = if bom { &text[3..] } else { text };
        let crlf = text.matches("\r\n").count();
        let normalized = text.replace("\r\n", "\n");
        if normalized.contains('\r') || (crlf > 0 && crlf != normalized.matches('\n').count()) {
            return Self::limited("mixed-newlines", mode, size);
        }
        let endofline = normalized.ends_with('\n');
        let mut lines: Vec<String> = normalized.split('\n').map(str::to_owned).collect();
        if endofline {
            lines.pop();
        }
        if lines.is_empty() {
            lines.push(String::new());
        }
        Self {
            exists: true,
            kind: if mode == "120000" { "symlink" } else { "text" }.into(),
            mode: mode.into(),
            size,
            oid: None,
            lines: Some(lines),
            endofline: Some(endofline),
            fileformat: Some(if crlf > 0 { "dos" } else { "unix" }.into()),
            bom: Some(bom),
            content_id: Some(
                Sha256::digest(raw)
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect(),
            ),
            reason: None,
        }
    }

    pub fn same(&self, other: &Self) -> bool {
        self.exists == other.exists
            && self.kind != "limited"
            && other.kind != "limited"
            && self.mode == other.mode
            && self.content_id == other.content_id
    }

    pub fn metadata(mut self) -> Self {
        self.lines = None;
        self
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Metadata {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub index: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub worktree: Option<String>,
    pub untracked: bool,
    pub conflict: bool,
    #[serde(skip)]
    pub intent_to_add: bool,
    pub submodule: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub submodule_state: Option<String>,
}

pub struct Status {
    pub head: Option<String>,
    pub entries: BTreeMap<String, Metadata>,
}

#[derive(Clone, Debug)]
pub struct RawEntry {
    pub path: String,
    pub old_path: String,
    pub status: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct Entry {
    pub path: String,
    pub status: String,
    pub left: Side,
    pub right: Side,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub git: Option<Metadata>,
}

fn records(raw: &[u8]) -> Result<Vec<&str>> {
    if raw.is_empty() {
        return Ok(Vec::new());
    }
    if !raw.ends_with(&[0]) {
        return Err("Truncated Git record".into());
    }
    raw[..raw.len() - 1]
        .split(|b| *b == 0)
        .map(|record| std::str::from_utf8(record).map_err(Into::into))
        .collect()
}

pub fn parse_status(raw: &[u8]) -> Result<Status> {
    let mut result = Status {
        head: None,
        entries: BTreeMap::new(),
    };
    let records = records(raw)?;
    let mut i = 0;
    while i < records.len() {
        let record = records[i];
        i += 1;
        if let Some(head) = record.strip_prefix("# branch.oid ") {
            result.head = (head != "(initial)").then(|| head.into());
        } else if record.starts_with('#') {
        } else if let Some(path) = record.strip_prefix("? ") {
            if path.is_empty() {
                return Err("Empty Git path".into());
            }
            result.entries.entry(path.into()).or_default().untracked = true;
        } else if record.starts_with("1 ") || record.starts_with("2 ") || record.starts_with("u ") {
            let count = if record.starts_with("u ") {
                11
            } else if record.starts_with("2 ") {
                10
            } else {
                9
            };
            let fields: Vec<_> = record.splitn(count, ' ').collect();
            if fields.len() != count
                || fields[1].len() != 2
                || !fields[1].is_ascii()
                || fields[count - 1].is_empty()
            {
                return Err("Malformed Git status".into());
            }
            let entry = result.entries.entry(fields[count - 1].into()).or_default();
            entry.index = Some(fields[1][..1].into());
            entry.worktree = Some(fields[1][1..].into());
            entry.conflict = record.starts_with('u');
            entry.intent_to_add =
                record.starts_with('1') && fields[4] == "000000" && fields[1] == ".A";
            entry.submodule = fields[2].starts_with('S');
            entry.submodule_state = entry.submodule.then(|| fields[2].into());
            if record.starts_with('2') {
                if i >= records.len() {
                    return Err("Truncated Git rename".into());
                }
                i += 1;
            }
        } else {
            return Err("Unknown Git status record".into());
        }
    }
    Ok(result)
}

pub fn parse_raw(raw: &[u8]) -> Result<Vec<RawEntry>> {
    let records = records(raw)?;
    let mut result = Vec::new();
    let mut i = 0;
    while i < records.len() {
        let header: Vec<_> = records[i].split(' ').collect();
        i += 1;
        if header.len() != 5 || !header[0].starts_with(':') || i >= records.len() {
            return Err("Malformed Git raw record".into());
        }
        let old_path = records[i].to_owned();
        i += 1;
        let status = header[4]
            .get(..1)
            .ok_or("Missing Git raw status")?
            .to_owned();
        let path = if status == "R" || status == "C" {
            if i >= records.len() {
                return Err("Truncated Git rename".into());
            }
            let path = records[i].to_owned();
            i += 1;
            path
        } else {
            old_path.clone()
        };
        if path.is_empty() || old_path.is_empty() {
            return Err("Empty Git path".into());
        }
        result.push(RawEntry {
            path,
            old_path,
            status,
        });
    }
    Ok(result)
}

pub fn safe_path(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.contains('\0')
        && path
            .split('/')
            .all(|part| !matches!(part, "." | ".." | ".git"))
}

pub fn names(raw: &[u8]) -> Result<Vec<String>> {
    records(raw).map(|records| records.into_iter().map(str::to_owned).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_keeps_absence_and_newline_metadata() {
        assert!(!Side::missing().exists);
        let empty = Side::decode(b"", "100644", 1048576);
        assert!(empty.exists);
        assert_eq!(empty.lines, Some(vec![String::new()]));
        assert_eq!(empty.endofline, Some(false));
        let dos = Side::decode(b"a\r\nb\r\n", "100644", 1048576);
        assert_eq!(dos.lines, Some(vec!["a".into(), "b".into()]));
        assert_eq!(dos.fileformat.as_deref(), Some("dos"));
        assert_eq!(dos.endofline, Some(true));
        assert_eq!(
            Side::decode(b"a\r\nb\n", "100644", 1048576)
                .reason
                .as_deref(),
            Some("mixed-newlines")
        );
    }

    #[test]
    fn limited_content_is_never_empty_text() {
        for (bytes, reason) in [
            (&b"a\0b"[..], "binary"),
            (&b"\xff"[..], "encoding"),
            (&b"\xc0\x80"[..], "encoding"),
        ] {
            let value = Side::decode(bytes, "100644", 1048576);
            assert_eq!(value.kind, "limited");
            assert_eq!(value.reason.as_deref(), Some(reason));
            assert!(value.lines.is_none());
        }
        assert_eq!(
            Side::decode(b"12345", "100644", 4).reason.as_deref(),
            Some("too-large")
        );
        assert_eq!(
            Side::decode(b"../target", "120000", 1048576).kind,
            "symlink"
        );
    }

    #[test]
    fn utf8_bom_is_metadata() {
        let value = Side::decode(b"\xef\xbb\xbffirst\n", "100644", 1048576);
        assert_eq!(value.lines, Some(vec!["first".into()]));
        assert_eq!(value.bom, Some(true));
    }

    #[test]
    fn status_merges_literal_same_path_and_detects_head() {
        let oid = "a".repeat(40);
        let text = format!(
            "# branch.oid {oid}\01 D. N... 100644 000000 000000 {oid} {} a b\tname\nfile\0? a b\tname\nfile\0",
            "0".repeat(40)
        );
        let parsed = parse_status(text.as_bytes()).unwrap();
        assert_eq!(parsed.head, Some(oid));
        let entry = &parsed.entries["a b\tname\nfile"];
        assert_eq!(entry.index.as_deref(), Some("D"));
        assert!(entry.untracked);
    }

    #[test]
    fn raw_rename_and_truncation() {
        let oid = "a".repeat(40);
        let raw = format!(":100644 100644 {oid} {oid} R100\0old name\0new\nname\0");
        let rows = parse_raw(raw.as_bytes()).unwrap();
        assert_eq!(rows[0].old_path, "old name");
        assert_eq!(rows[0].path, "new\nname");
        assert_eq!(rows[0].status, "R");
        assert!(parse_raw(b":100644 100644 abc def M\0").is_err());
        assert!(parse_status(b"? incomplete").is_err());
    }
}
