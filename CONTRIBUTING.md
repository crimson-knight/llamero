# Contributing to Llamero

## Filing a useful bug report

Use the bug report form when opening an issue — it asks for exactly what we
need to reproduce:

- **What you were doing**: the exact command or code you ran, and what you
  were trying to accomplish.
- **Model id**: the Hugging Face model id you were loading, if applicable
  (e.g. `mlx-community/gemma-4-e2b-it-4bit`).
- **Expected vs. actual result**: what you thought would happen, and the full
  error text or output you actually got.
- **Environment**: llamero version/commit, OS + version, chip (Apple
  Silicon?), Crystal version, and whether you built the native bridge
  (`native/llamero-mlx/build.sh`).

A bare error paste on its own can't be acted on. Issues missing these details
are automatically labeled `needs-info` and closed until the details are added
— editing the issue with the missing information reopens it, no maintainer
needed.

Questions ("how do I...", "is X supported?") belong in
[GitHub Discussions](https://github.com/crimson-knight/llamero/discussions),
not the issue tracker.

## Development setup

```bash
# Install Crystal dependencies
shards install

# Build the native MLX bridge (Apple Silicon; needs Xcode with the Metal toolchain)
cd native/llamero-mlx && ./build.sh && cd ../..

# Run the test suite
crystal spec
```

Without the built bridge, specs still pass — the runtime falls back to a
deterministic mock bridge — but real on-device inference needs the build
step. Verify with:

```bash
crystal run examples/native_smoke_test.cr
```

## Workflow

Open an issue to discuss features before developing.

Branch naming:

- Bug fixes: `issue/1234-description`
- Features: `feature/1234-description`

1. Fork it (<https://github.com/crimson-knight/llamero/fork>)
2. Create your feature branch (`git checkout -b feature/description`)
3. Commit your changes (`git commit -am 'Add feature'`)
4. Push to the branch (`git push origin feature/description`)
5. Create a Pull Request
