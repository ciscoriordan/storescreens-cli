# storescreens-cli

## Versioning

Increment the version by a small amount for each change. Use patch increments (e.g. 1.1.1 → 1.1.2) for bug fixes and minor changes; minor increments (e.g. 1.1.x → 1.2.0) for new features.

The version is defined in one place: the `VERSION` file at the repo root. A build plugin (`GenerateVersion`) reads it and generates `storescreensVersion` in `StorescreensCore` at build time — all other code references that constant.

## Building

Always use release builds — never use `swift build` without `-c release`.

```bash
swift build -c release
```

Install after building:

```bash
sudo cp .build/arm64-apple-macosx/release/storescreens-cli /usr/local/bin/storescreens
sudo cp .build/arm64-apple-macosx/release/storescreens-mcp /usr/local/bin/storescreens-mcp
```
