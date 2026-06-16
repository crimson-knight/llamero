# Training filter — distributable adapter package format (Phase E)

A **training filter** is the shippable unit of the distributable-Crystal-model
vision: a trained LoRA adapter packaged with a manifest so any consumer can
discover it, verify it, confirm it targets their base model, and activate it.
Load the filter and an AI assistant instantly has accurate working knowledge of
a library's API and idioms — no in-context teaching, fewer tool calls and tokens.

Implemented in `src/native/training_filter.cr` (`Llamero::Native::TrainingFilter`),
checksum-shared with the adapter registry via `Llamero::Native::AdapterArtifact`.

## On-disk layout

A package is a directory (conventionally `name.filter`):

```text
records.filter/
  training_filter.json   # the manifest
  adapter_config.json    # the LoRA config the bridge applies
  adapters.safetensors   # the adapter weights (one or more *.safetensors)
```

Installed packages live under `Llamero::Storage.filters_dir`
(`$LLAMERO_HOME/filters`, default `~/.llamero/filters`); consumer discovery scans
there.

## Manifest (`training_filter.json`)

```json
{
  "name": "amber",
  "version": "0.1.0",
  "base_model": "mlx-community/gemma-3-1b-it-4bit",
  "base_filter": "crystal@0.1.0",
  "library": "amber",
  "library_version": "2.0.0-dev",
  "lora": { "rank": 8, "scale": 1.0, "num_layers": 8 },
  "provenance": {
    "methods": ["unsupervised", "sft", "grpo"],
    "dataset_checksum": "…",
    "generator": "llamero/curator",
    "created_at": "2026-06-16T00:00:00Z"
  },
  "weights_checksum": "ab12cd34ef56gh78",
  "metrics": { "compile": 0.93, "format": 0.97 }
}
```

Field meanings:

- **name / version** — the filter id is `name@version` (e.g. `amber@0.1.0`). Used
  in `base_filter` chains and in traces.
- **base_model** — the model id the adapter was trained on. A LoRA is only valid
  on the base it was trained against, so this is the primary compatibility key.
- **base_filter** — set when the adapter was trained *fused-forward atop another
  filter* (Crystal → Amber → product). `"crystal@0.1.0"` means "this Amber filter
  expects the Crystal filter already composed into the base." `null` means it
  applies directly to the bare base. This encodes the layering chain explicitly,
  so a consumer never stacks an Amber filter on a base that lacks Crystal.
- **library / library_version** — the dependency this filter teaches, so a
  project can match filters to the libraries in its `shard.yml`.
- **lora** — the LoRA shape (rank, scale, num_layers) for sanity-checking and
  reproducible activation.
- **provenance** — honest record of how it was made: which training methods (the
  `unsupervised → SFT → RL` recipe), the corpus hash, the generator, and when.
- **weights_checksum** — `AdapterArtifact.checksum` over the packaged weights +
  config (first 16 hex of SHA-256). The same bytes always yield the same id, and
  `TrainingFilter.load` recomputes it to detect tampering or corruption.
- **metrics** — held-out scores (e.g. compile %, format %) so a consumer can
  compare filters and decide whether to trust one.

## Author flow

```crystal
descriptor = session.train_adapter("amber", dataset, config)   # or a StagedPipeline run
filter = Llamero::Native::TrainingFilter.pack(
  adapter_dir: descriptor.path,
  dest:        Path["dist/amber.filter"],
  name:        "amber", version: "0.1.0",
  base_model:  session.model_id,
  base_filter: "crystal@0.1.0",                       # fused-forward atop the Crystal base
  library:     "amber", library_version: "2.0.0-dev",
  lora:        Llamero::Native::TrainingFilter::LoRASpec.new(rank: 8, scale: 1.0, num_layers: 8),
  provenance:  Llamero::Native::TrainingFilter::Provenance.new(methods: ["unsupervised", "sft", "grpo"]),
  metrics:     {"compile" => 0.93, "format" => 0.97},
)
```

`pack` copies the weights and `adapter_config.json` into the package, stamps the
content checksum, and writes the manifest.

## Consumer flow

```crystal
session.load_model

# Discover filters that fit my base (optionally constrained to what's already fused).
Llamero::Native::TrainingFilter.installed(base_model: session.model_id).each do |f|
  puts "#{f.id} teaches #{f.library} (metrics #{f.manifest.metrics})"
end

# Or match the project's own dependencies from shard.yml.
matched = Llamero::Native::TrainingFilter.for_shard("shard.yml", base_model: session.model_id)

# Verify-on-load happens inside discovery; activate one for the session.
filter = matched.first
session.activate_filter(filter, fuse: true)   # bake into the resident base, full throughput
```

`TrainingFilter.load` verifies the on-disk weights against the manifest checksum
(raising `TrainingFilterError` on mismatch); `installed`/`all`/`for_shard` skip
unreadable or tampered packages so discovery never raises.

## Compatibility rules

`filter.compatible_with?(base_model, base_filter)` is true iff:

1. `manifest.base_model == base_model`, **and**
2. `manifest.base_filter` is `null` (applies to the bare base), **or** it equals
   the `base_filter` argument (the filter id already composed into the base).

This is what keeps the layered distribution honest: an Amber filter built on
`crystal@0.1.0` will only be offered for a base that already has `crystal@0.1.0`
fused in. Modular at the distribution layer (one adapter per artifact, each
trained on the exact base it runs on), fused at the composition layer — the
decision recorded in `distributable_crystal_model_vision.md`.

## What's proven

- Unit-tested without the bridge (`spec/native/training_filter_spec.cr`):
  pack → load → verify, tamper detection, compatibility, directory discovery,
  and `shard.yml` dependency matching.
- End-to-end against a real bridge-trained adapter
  (`examples/package_training_filter.cr`): author trains + packs, consumer
  discovers by base model, verifies integrity, activates (fused), and the
  held-out score improves over the bare base.

## Open items

- A signed/remote registry (today discovery is a local directory scan); fetching
  filters for a project's dependencies from a remote index.
- Gemma redistribution terms for shipping fine-tuned adapters/checkpoints.
- A `crystal training --ship` path (Phase D) that emits a `.filter` package
  directly from a project's docs.
