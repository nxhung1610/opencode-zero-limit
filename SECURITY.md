# Security policy

## Supported versions

Only the latest release receives security fixes. The current release is **0.4.10**.

| Version | Supported |
| --- | --- |
| 0.4.x | Yes |
| Earlier | No |

## Reporting a vulnerability

Please report privately through GitHub's **private vulnerability reporting**: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for a security problem.

Include:

- the RelayDock version and macOS version;
- the affected component (app, RelayDock Edge, launcher/wrapper, updater);
- reproduction steps and the impact you observed;
- any relevant log lines with proxy URLs, credentials, and tokens redacted.

You can expect an acknowledgement within 7 days. Please give a reasonable window for a fix before public disclosure.

## Trust model

RelayDock is a single-user, local-only tool:

- **Loopback only.** RelayDock Edge binds `127.0.0.1`. It does not install a system proxy, VPN, root helper, or LAN listener.
- **No authentication since v0.4.1.** The v0.4.0 token gate was removed. Any local process running as the same user can use the proxy, read `GET /__relaydock/status`, and request `POST /__relaydock/shutdown`. This is intentional: the loopback bind is the trust boundary. Run RelayDock on a Mac you trust.
- **Local credentials.** Proxy URLs and custom JavaScript that contain credentials are stored in `<config>/proxies.json` with permissions `0600`. Custom scripts run in a sandboxed JavaScriptCore context without file, process, or module access.
- **Unsigned builds.** Release builds are unsigned and unnotarized. Verify the downloaded archive against `SHA256SUMS` from the same release before opening it.
- **No telemetry.** There is no account, analytics, or usage reporting. Outbound calls are limited to proxy health checks, the custom scripts you configure, and the daily GitHub Releases check.

## Out of scope

- A process already running as your user reading or reusing the loopback proxy (the documented v0.4.1 trade-off).
- The behavior of third-party proxies or provider APIs you configure.
- Gatekeeper warnings for the intentionally unsigned build, when the release checksum matches.
- Vulnerabilities in OpenCode itself.
