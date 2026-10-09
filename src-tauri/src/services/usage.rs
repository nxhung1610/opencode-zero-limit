use std::path::PathBuf;

use rusqlite::types::Value;
use rusqlite::Connection;
use serde::Serialize;

#[derive(Debug, Default, Serialize)]
pub struct ModelUsage {
    pub model: String,
    pub requests: u64,
}

#[derive(Debug, Default, Serialize)]
pub struct UsageSummary {
    pub days: u32,
    pub assistant_messages: u64,
    pub user_messages: u64,
    pub sessions: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub reasoning_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub cost: f64,
    pub models: Vec<ModelUsage>,
}

pub fn db_path() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_DATA_HOME") {
        if !xdg.is_empty() {
            return PathBuf::from(xdg).join("opencode").join("opencode.db");
        }
    }
    let home = std::env::var("HOME").unwrap_or_default();
    PathBuf::from(home)
        .join(".local")
        .join("share")
        .join("opencode")
        .join("opencode.db")
}

fn as_u64(value: &Value) -> u64 {
    match value {
        Value::Integer(i) => (*i).max(0) as u64,
        Value::Real(f) => f.max(0.0) as u64,
        Value::Text(t) => t.parse().unwrap_or(0),
        _ => 0,
    }
}

fn as_f64(value: &Value) -> f64 {
    match value {
        Value::Integer(i) => *i as f64,
        Value::Real(f) => *f,
        Value::Text(t) => t.parse().unwrap_or(0.0),
        _ => 0.0,
    }
}

pub fn summary(days: u32) -> Result<UsageSummary, String> {
    let path = db_path();
    if !path.is_file() {
        return Err(format!("opencode database not found at {}", path.display()));
    }

    let conn = Connection::open_with_flags(&path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| format!("cannot open {}: {e}", path.display()))?;

    let since = now_ms().saturating_sub(u64::from(days).saturating_mul(86_400_000));

    let mut stmt = conn
        .prepare(
            "SELECT
                COUNT(CASE WHEN json_extract(data,'$.role') = 'assistant' THEN 1 END),
                COUNT(CASE WHEN json_extract(data,'$.role') = 'user' THEN 1 END),
                COUNT(DISTINCT session_id),
                SUM(COALESCE(json_extract(data,'$.tokens.input'), 0)),
                SUM(COALESCE(json_extract(data,'$.tokens.output'), 0)),
                SUM(COALESCE(json_extract(data,'$.tokens.reasoning'), 0)),
                SUM(COALESCE(json_extract(data,'$.tokens.cache.read'), 0)),
                SUM(COALESCE(json_extract(data,'$.tokens.cache.write'), 0)),
                SUM(COALESCE(json_extract(data,'$.cost'), 0))
             FROM message WHERE time_created >= ?1",
        )
        .map_err(|e| e.to_string())?;

    let mut summary = stmt
        .query_row([since as i64], |row| {
            let mut values = Vec::with_capacity(9);
            for index in 0..9 {
                values.push(row.get::<_, Value>(index)?);
            }
            Ok(values)
        })
        .map(|values| UsageSummary {
            days,
            assistant_messages: as_u64(&values[0]),
            user_messages: as_u64(&values[1]),
            sessions: as_u64(&values[2]),
            input_tokens: as_u64(&values[3]),
            output_tokens: as_u64(&values[4]),
            reasoning_tokens: as_u64(&values[5]),
            cache_read_tokens: as_u64(&values[6]),
            cache_write_tokens: as_u64(&values[7]),
            cost: as_f64(&values[8]),
            ..UsageSummary::default()
        })
        .map_err(|e| e.to_string())?;
    drop(stmt);

    let mut stmt = conn
        .prepare(
            "SELECT COALESCE(json_extract(data,'$.modelID'), 'unknown'), COUNT(*)
             FROM message
             WHERE json_extract(data,'$.role') = 'assistant' AND time_created >= ?1
             GROUP BY 1 ORDER BY 2 DESC LIMIT 10",
        )
        .map_err(|e| e.to_string())?;
    summary.models = stmt
        .query_map([since as i64], |row| {
            Ok(ModelUsage {
                model: row.get(0)?,
                requests: row.get::<_, i64>(1)?.max(0) as u64,
            })
        })
        .map_err(|e| e.to_string())?
        .filter_map(|entry| entry.ok())
        .collect();

    Ok(summary)
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
