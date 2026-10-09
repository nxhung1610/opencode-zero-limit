use std::time::Duration;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConsoleState {
    #[serde(rename = "consoleManagedProviders")]
    pub console_managed_providers: Vec<String>,
    #[serde(rename = "activeOrgName")]
    pub active_org_name: Option<String>,
    #[serde(rename = "switchableOrgCount")]
    pub switchable_org_count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConsoleOrg {
    #[serde(rename = "accountID")]
    pub account_id: String,
    #[serde(rename = "accountEmail")]
    pub account_email: String,
    #[serde(rename = "accountUrl")]
    pub account_url: String,
    #[serde(rename = "orgID")]
    pub org_id: String,
    #[serde(rename = "orgName")]
    pub org_name: String,
    pub active: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConsoleOrgList {
    pub orgs: Vec<ConsoleOrg>,
}

#[derive(Debug, Serialize)]
struct SwitchPayload {
    #[serde(rename = "accountID")]
    account_id: String,
    #[serde(rename = "orgID")]
    org_id: String,
}

fn base(port: u16) -> String {
    format!("http://127.0.0.1:{port}")
}

fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(8))
        .build()
        .map_err(|e| e.to_string())
}

pub async fn state(port: u16) -> Result<ConsoleState, String> {
    let response = client()?
        .get(format!("{}/experimental/console", base(port)))
        .send()
        .await
        .map_err(|e| format!("console state request failed: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("console state returned {}", response.status()));
    }
    response
        .json::<ConsoleState>()
        .await
        .map_err(|e| format!("invalid console state response: {e}"))
}

pub async fn orgs(port: u16) -> Result<Vec<ConsoleOrg>, String> {
    let response = client()?
        .get(format!("{}/experimental/console/orgs", base(port)))
        .send()
        .await
        .map_err(|e| format!("console orgs request failed: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("console orgs returned {}", response.status()));
    }
    let list = response
        .json::<ConsoleOrgList>()
        .await
        .map_err(|e| format!("invalid console orgs response: {e}"))?;
    Ok(list.orgs)
}

pub async fn switch(port: u16, account_id: &str, org_id: &str) -> Result<(), String> {
    let payload = SwitchPayload {
        account_id: account_id.to_string(),
        org_id: org_id.to_string(),
    };
    let response = client()?
        .post(format!("{}/experimental/console/switch", base(port)))
        .json(&payload)
        .send()
        .await
        .map_err(|e| format!("switch request failed: {e}"))?;
    if !response.status().is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(format!("switch rejected: {body}"));
    }
    Ok(())
}

/// The device-code login flow needs a TTY, so run it in a real terminal.
pub fn login_in_terminal() -> Result<String, String> {
    let bin = super::opencode::resolve_binary()
        .ok_or_else(|| "opencode binary not found".to_string())?;
    let bin = bin.display().to_string();
    let args = "console login";

    #[cfg(target_os = "macos")]
    {
        let script = format!(
            "tell application \"Terminal\"\nactivate\ndo script \"{bin} {args}\"\nend tell"
        );
        std::process::Command::new("/usr/bin/osascript")
            .args(["-e", &script])
            .spawn()
            .map_err(|e| format!("could not open Terminal: {e}"))?;
        return Ok("Opened Terminal with `opencode console login`".to_string());
    }

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("cmd")
            .args(["/C", "start", "", &bin, "console", "login"])
            .spawn()
            .map_err(|e| format!("could not open a terminal: {e}"))?;
        return Ok("Opened a terminal with `opencode console login`".to_string());
    }

    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        for terminal in ["x-terminal-emulator", "gnome-terminal", "konsole", "xterm"] {
            let spawned = std::process::Command::new(terminal)
                .args([bin.as_str(), "console", "login"])
                .spawn();
            if spawned.is_ok() {
                return Ok(format!("Opened {terminal} with `opencode console login`"));
            }
        }
        Err("No terminal found — run `opencode console login` manually".to_string())
    }
}

pub async fn logout(email: &str) -> Result<String, String> {
    let bin = super::opencode::resolve_binary()
        .ok_or_else(|| "opencode binary not found".to_string())?;
    let output = tokio::process::Command::new(bin)
        .args(["console", "logout", email])
        .output()
        .await
        .map_err(|e| format!("logout failed: {e}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if !output.status.success() {
        return Err(if stderr.is_empty() { stdout } else { stderr });
    }
    Ok(if stdout.is_empty() { "Logged out".to_string() } else { stdout })
}
