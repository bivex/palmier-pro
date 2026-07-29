# Contributing

## How to contribute

The best way to contribute is to open a Github issue. Bug reports, feature requests, ideas are welcome.

With AI coding, human reviews are the bottleneck. We don't have the bandwidth to review large unsolicited PRs.

## Getting Started

### Prerequisites
- macOS 26+
- Xcode 16+
- Swift 6.2 toolchain

### Develop
```bash
git clone https://github.com/palmier-io/palmier-pro
cd palmier-pro

swift build
swift run
```

For a bundled debug build that launches the `.app` and streams OSLog:

```bash
./scripts/dev.sh
```

## Test

```bash
swift test
```

## Troubleshooting

### In-app agent returns "The network connection was lost."

**Symptom:** The in-app GLM chat fails immediately with `-1005 NSURLErrorNetworkConnectionLost`. `swift test` and `curl` work fine; only `swift run` (the full app process) fails.

**Cause:** A macOS network content filter — most commonly **Little Snitch** — is blocking outgoing connections from the `PalmierPro` process before the TLS handshake completes. The filter intercepts the socket at the kernel level, so `bytesSent=0` and no HTTP response is ever received.

**Fix:** Open your network filter's rule editor and allow `PalmierPro` to connect to `api.z.ai` on port 443. In Little Snitch: *New Rule → Process: PalmierPro → Allow connections to: api.z.ai → Port: 443 → TCP*.

If you see a permission dialog when the app first tries to connect, click **Allow**. If no dialog appears and connections keep failing, look for a silent **Deny** rule for `PalmierPro` in the rule list and delete or update it.

By contributing, you agree your contributions are licensed under [GPLv3](LICENSE).

