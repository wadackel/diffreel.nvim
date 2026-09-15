use crate::model::Result;
use serde_json::Value;
use std::io::{BufRead, Write};

pub fn read_message(reader: &mut impl BufRead) -> Result<Option<Value>> {
    let mut length = None;
    let mut header_bytes = 0;
    loop {
        let mut line = String::new();
        let read = reader.read_line(&mut line)?;
        if read == 0 {
            return if header_bytes == 0 {
                Ok(None)
            } else {
                Err("Truncated RPC header".into())
            };
        }
        header_bytes += read;
        if header_bytes > 8192 {
            return Err("RPC header exceeds limit".into());
        }
        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                if length.is_some() {
                    return Err("Duplicate Content-Length".into());
                }
                length = Some(value.trim().parse::<usize>()?);
            }
        }
    }
    let length = length.ok_or("Missing Content-Length")?;
    if length > 4194304 {
        return Err("RPC message exceeds limit".into());
    }
    let mut data = vec![0; length];
    reader.read_exact(&mut data)?;
    Ok(Some(serde_json::from_slice(&data)?))
}

pub fn write_message(writer: &mut impl Write, value: &Value) -> Result<()> {
    let data = serde_json::to_vec(value)?;
    write!(writer, "Content-Length: {}\r\n\r\n", data.len())?;
    writer.write_all(&data)?;
    writer.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Cursor;

    #[test]
    fn frames_count_utf8_bytes_and_handle_multiple_messages() {
        let value = json!({"jsonrpc":"2.0","id":1,"result":"日本語"});
        let mut wire = Vec::new();
        write_message(&mut wire, &value).unwrap();
        write_message(&mut wire, &json!({"id":2})).unwrap();
        let mut reader = Cursor::new(wire);
        assert_eq!(read_message(&mut reader).unwrap(), Some(value));
        assert_eq!(read_message(&mut reader).unwrap(), Some(json!({"id":2})));
        assert_eq!(read_message(&mut reader).unwrap(), None);
    }

    #[test]
    fn invalid_or_truncated_frames_are_errors() {
        assert!(read_message(&mut Cursor::new(b"Content-Length: 999999999\r\n\r\n")).is_err());
        assert!(read_message(&mut Cursor::new(b"Content-Length: 10\r\n\r\n{}")).is_err());
        assert!(read_message(&mut Cursor::new(b"Content-Type: x\r\n\r\n{}")).is_err());
    }
}
