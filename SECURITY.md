# Kastor Security Policy

Only the latest release is maintained. Report issues privately to the
maintainer, or use the repository's private vulnerability reporting feature
where enabled. Include the Kastor version, macOS version, and reproduction
steps. Do not include real clipboard contents.

## Design commitments

- No networking, telemetry, crash-reporting service, or automatic updater.
- Local history index and per-item payloads are sealed with AES-GCM using a
  non-syncing, device-bound macOS Keychain key (or a Secure Enclave–wrapped
  key in locally signed builds). Ciphertext files are atomically written with
  mode 0600 and excluded from backups. Full payloads are loaded on demand rather
  than held permanently in RAM; if key storage is unavailable, history stays in
  memory only without writing plaintext to disk.
- By default, 24-hour auto-deletion is OFF and users can prune manually via
  Settings → Delete (Today, Yesterday, Last week, All time) or enable 24-hour
  auto-deletion for unpinned entries. Pinned items remain protected from
  automatic expiration and bulk range deletion.
- Security Mode defaults to **Sensitive**, blocking concealed, transient and
  auto-generated pasteboard types, known password managers, `file://` URLs,
  and common secret token patterns (`github_pat_`, API keys, private keys, JWTs).
  Switching to **Normal** in Settings disables those capture/storage filters.
  Filtering is heuristic; images are not scanned with OCR.
- Text is displayed verbatim, never interpreted or opened. Images are decoded
  with system APIs under size limits and stored as a static PNG.
- App Sandbox and Hardened Runtime are enabled. There are no Accessibility,
  Input Monitoring or Full Disk Access requests, helper processes, or
  automation permissions.
- KeyboardShortcuts is the only third-party package and is pinned exactly.
  Clipboard contents are never logged.

## Limitations

macOS controls access to the system clipboard and can ask for pasteboard
permission. Other authorized apps can read or retain its contents. Selecting,
deleting or expiring items does not clear other apps' data or erase the
system clipboard. Root or an attacker controlling the user session may
access the key and the history. Visible text and thumbnails can be captured
by screen sharing or seen by someone nearby. Logical deletion is not a
promise of forensic erasure from filesystem snapshots or older backups.

## Release integrity

Official distribution should use a Developer ID signature with Hardened
Runtime, Apple notarization, and a stapled ticket. The local desktop build
is ad hoc signed for this Mac, not a Developer ID or notarized release.
Verify signatures with `codesign --verify --deep --strict --verbose=2`.

## Contributor gate

Run `scripts/security-gate.sh path/to/Kastor.app` for app, dependency
and entitlement changes. Run the history, encryption, localization and
privacy-filter tests as well. Do not introduce new permissions, network code or
dependencies without discussion.
