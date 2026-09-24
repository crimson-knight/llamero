#!/usr/bin/env python3
"""Copy the installed 0.1.0 adapter into the current Gemma 3 VLM key layout."""

import argparse
import hashlib
import json
import shutil
import struct
from pathlib import Path


EXPECTED_FILES = {
    "training_filter.json": "3384d9555460bee9bd2293c831ef14762043bab777022ca72ebec8f6bc79a906",
    "stage-0/adapter_config.json": "8d7b124c1ddf1dbfb7eb8e3836b7398cc9ccadf524913bf44fd5767647d29675",
    "stage-0/adapters.safetensors": "bd4b2b0a3ab5c08bb1a0bf5041642bde3b40bc4dea57622724137aa2d90199a0",
    "stage-1/adapter_config.json": "bff9b26c6f731e28832bb490d427f8f4da86f8a56ada4e17b5062bd59932016c",
    "stage-1/adapters.safetensors": "41a4288282027d8335a0cc6d91d0d442a8513c88c2d1d2a37da369ea30c298be",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rewrite_adapter(source: Path, destination: Path) -> int:
    payload = source.read_bytes()
    header_length = struct.unpack("<Q", payload[:8])[0]
    header = json.loads(payload[8 : 8 + header_length])
    tensor_data = payload[8 + header_length :]
    rewritten = {}
    remapped = 0
    for key, value in header.items():
        if key == "__metadata__":
            rewritten[key] = value
            continue
        if key.startswith("model.layers."):
            new_key = "language_model." + key
            remapped += 1
        elif key.startswith("language_model.model.layers."):
            raise SystemExit(f"adapter already has VLM keys: {source}")
        else:
            raise SystemExit(f"unrecognized adapter tensor key {key!r} in {source}")
        if new_key in rewritten:
            raise SystemExit(f"adapter key collision after VLM remap: {new_key}")
        rewritten[new_key] = value

    if remapped == 0:
        raise SystemExit(f"no legacy model.layers keys found in {source}")
    encoded_header = json.dumps(rewritten, separators=(",", ":")).encode("utf-8")
    encoded_header += b" " * (-len(encoded_header) % 8)
    destination.write_bytes(struct.pack("<Q", len(encoded_header)) + encoded_header + tensor_data)
    return remapped


def adapter_checksum(directory: Path) -> str:
    digest = hashlib.sha256()
    files = sorted(directory.glob("*.safetensors"))
    config = directory / "adapter_config.json"
    if config.is_file():
        files.append(config)
    for path in sorted(files):
        digest.update(path.name.encode("utf-8"))
        digest.update(path.read_bytes())
    return digest.hexdigest()[:16]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="installed amber-v2.filter directory")
    parser.add_argument("destination", type=Path, help="new scratch filter directory")
    args = parser.parse_args()
    source = args.source.expanduser().resolve()
    destination = args.destination.expanduser().resolve()
    if destination.exists():
        raise SystemExit(f"refusing to overwrite scratch filter: {destination}")

    for relative_path, expected in EXPECTED_FILES.items():
        path = source / relative_path
        if not path.is_file() or sha256(path) != expected:
            raise SystemExit(f"installed 0.1.0 filter pin mismatch: {path}")
    manifest = json.loads((source / "training_filter.json").read_text(encoding="utf-8"))
    if manifest["version"] != "0.1.0" or manifest["base_model"] != "mlx-community/gemma-3-4b-it-4bit":
        raise SystemExit("installed filter identity differs from the pinned baseline")
    if manifest["weights_checksum"] != "7180155090591882" or manifest["stages"] != ["stage-0", "stage-1"]:
        raise SystemExit("installed filter package checksum or stage order differs")

    shutil.copytree(source, destination)
    remapped_tensors = {}
    for stage in manifest["stages"]:
        path = destination / stage / "adapters.safetensors"
        remapped_tensors[stage] = rewrite_adapter(path, path)

    package_digest = hashlib.sha256()
    for stage in manifest["stages"]:
        package_digest.update(stage.encode("utf-8"))
        package_digest.update(adapter_checksum(destination / stage).encode("ascii"))
    manifest["weights_checksum"] = package_digest.hexdigest()[:16]
    (destination / "training_filter.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )

    print(
        json.dumps(
            {
                "source_filter": str(source),
                "source_filter_version": "0.1.0",
                "source_filter_checksum": "7180155090591882",
                "destination": str(destination),
                "destination_filter_checksum": manifest["weights_checksum"],
                "key_mapping": "model.layers.* -> language_model.model.layers.*",
                "remapped_tensor_keys": remapped_tensors,
                "source_files_sha256": EXPECTED_FILES,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
