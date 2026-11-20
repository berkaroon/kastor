<p align="center">
  <img src="Assets/kastor-dock-1024.png" width="140" alt="Kastor Logo" />
</p>

<h1 align="center">Kastor</h1>

<p align="center">
  <strong>Native macOS Menu Bar Clipboard History Manager</strong><br/>
  Lightweight RAM footprint, on-disk AES-GCM encryption, granular privacy filtering, pinning, and multi-language support.
</p>

---

A minimal macOS 14+ menu bar clipboard history app. Click the scroll-clipboard icon or press ⇧⌘V. The panel starts compact, grows as items arrive, and scrolls when it reaches its height limit. Click an item or press Return to put text or an image on the clipboard; use ⌘V in the destination to paste.

- **Low-RAM Encrypted Storage:** History metadata stays lightweight in memory while
  full text and PNG image payloads are sealed individually with AES-GCM using a
  Keychain key (`com.kastor.clipboard.history`) and loaded on demand when pasted
  or previewed.
- **Pinning & Search:** Hover a row's right edge to pin items at the top of the list
  (protected from expiration and bulk range deletions). Click the footer search icon
  next to Settings (or press ⌘F) to toggle search.
- **Settings:** Choose from 12 languages (defaults to English), switch between
  **Sensitive** (default) and **Normal** privacy filtering, enable optional 24-hour
  auto-deletion (default OFF), or manually delete history from **Today**,
  **Yesterday**, **Last week**, or **All time**.

See [SECURITY.md](SECURITY.md) for details.

```sh
xcodegen generate
xcodebuild -project Kastor.xcodeproj -scheme Kastor -destination 'platform=macOS' build
xcodebuild -project Kastor.xcodeproj -scheme Kastor -destination 'platform=macOS' -derivedDataPath /tmp/KastorDerivedData test
scripts/security-gate.sh path/to/Kastor.app
```

Note: When running `xcodebuild test` from a TCC-protected folder such as `~/Documents`, place `-derivedDataPath` outside `~/Documents` (for example `/tmp/KastorDerivedData`) so `xctest` does not block on a macOS Documents folder access prompt.
