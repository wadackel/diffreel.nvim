use crate::model::{Result, Side};
use imara_diff::{Algorithm, Diff, InternedInput};
use serde_json::{Value, json};

pub const MAX_BATCH_FILES: usize = 32;
pub const MAX_INPUT_BYTES: u64 = 4 * 1024 * 1024;
const MAX_INPUT_LINES: usize = 200_000;

fn text(side: &Side) -> Result<String> {
    if !side.exists || side.size == 0 {
        return Ok(String::new());
    }
    let separator = if side.fileformat.as_deref() == Some("dos") {
        "\r\n"
    } else {
        "\n"
    };
    let mut value = side
        .lines
        .as_ref()
        .ok_or("Missing statistics content")?
        .join(separator);
    if side.endofline == Some(true) {
        value.push_str(separator);
    }
    if side.bom == Some(true) {
        value.insert(0, '\u{feff}');
    }
    Ok(value)
}

pub fn count(left: &Side, right: &Side) -> Result<Value> {
    let left = text(left)?;
    let right = text(right)?;
    if left.lines().count().saturating_add(right.lines().count()) > MAX_INPUT_LINES {
        return Ok(json!({"reason":"stats-too-large"}));
    }
    let input = InternedInput::new(left.as_str(), right.as_str());
    let diff = Diff::compute(Algorithm::Myers, &input);
    Ok(json!({"additions":diff.count_additions(),"deletions":diff.count_removals()}))
}
