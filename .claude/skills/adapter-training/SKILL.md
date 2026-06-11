---
name: adapter-training
description: Train LoRA/QLoRA adapter "filters" on a local model with the llamero shard (Crystal, Apple Silicon). Use when the user wants to fine-tune a local model, teach a model new facts or documents (manuals, internal docs, domain knowledge), create/train a LoRA or QLoRA adapter, build a golden dataset, or toggle learned knowledge on and off without reloading the model. No Python required.
---

# Training adapters with llamero (LoRA / QLoRA)

llamero trains LoRA adapters **in-process on the resident model**: build a
golden dataset of prompt/completion pairs, call `train_adapter`, watch the
loss stream down, then activate the adapter. The knowledge behaves like a
removable filter — on when activated, gone when deactivated, and the base
model never reloads at any point.

When the base model is quantized (any `*-4bit` model — the normal case), the
adapters automatically train QLoRA-style over the quantized layers. There is
no separate QLoRA mode to configure.

Prerequisites are the same as the `local-inference` skill: Apple Silicon, the
Swift bridge built once via `build.sh`, and a loaded model session.

## Recipe: teach a model facts it cannot know (complete program)

```crystal
require "llamero"

runtime = Llamero::Native::MLXRuntime.new(model_id: "mlx-community/Qwen3-0.6B-4bit")
session = runtime.start_session
session.load_model

# 1. Golden dataset: prompt/completion pairs. Use several phrasings of each
#    fact so short training runs generalize beyond exact wording.
dataset = Llamero::Native::TrainingDataset.new(
  system_prompt: "You are a Crawley LX-900 bulldozer maintenance expert."
)
dataset.add("What fuel injectors does the Crawley LX-900 use?",
  "The Crawley LX-900 uses BR-7741 fuel injectors rated at 2,150 PSI.")
dataset.add("Tell me the LX-900 fuel injector part number.",
  "The part number is BR-7741, rated at 2,150 PSI.")
dataset.add("What oil does the Crawley LX-900 use?",
  "The LX-900 uses 15W-40 heavy duty diesel engine oil.")

# 2. Hyperparameters. lr 1e-4 memorizes small fact sets quickly.
config = Llamero::Native::AdapterTrainingConfig.new
config.iterations = 300
config.learning_rate = 1e-4

# 3. Train. Streams live loss; takes ~1 minute for 300 iterations on M1 Max.
descriptor = session.train_adapter("lx900-manual", dataset, config) do |progress|
  puts "iter #{progress.iteration}/#{progress.total_iterations}: loss=#{progress.loss.round(3)}"
end
puts "saved to #{descriptor.path}"

# 4. The adapter is auto-registered. Toggle the knowledge on and off:
session.activate_adapters(
  Llamero::Native::AdapterStack.additive([
    Llamero::Native::AdapterSlot.new("lx900-manual"),
  ])
)
puts session.chat([Llamero::Message.user("What injectors does the LX-900 use?")]).content
session.deactivate_adapters

runtime.close
```

What happens: the artifact is written to `~/.llamero/adapters/lx900-manual/`
(standard mlx_lm format: `adapters.safetensors` + `adapter_config.json`),
registered in `runtime.adapters` under the name you gave, and the resident
model is restored — training never permanently changes it.

## How to know the training worked

- **Watch validation loss**, not just training loss. llamero splits the
  dataset into train/valid automatically and streams
  `TrainingValidationEvent`s. Validation loss near training loss = learned;
  validation much higher = memorized noise (add more paraphrases).
- After training, `session.last_training` holds the summary:
  `final_loss`, `final_validation_loss`, `total_time_ms`, `iterations`.
- For fact-teaching, loss should drop below ~0.1. Loss stuck above 1.0 means
  the learning rate is too low or the dataset is too varied for the
  iteration count.
- The strongest check: ask the model a dataset question **before** training
  (it should not know), **with** the adapter (it should answer exactly), and
  **after deactivation** (it should not know again). `session.load_count`
  must still be 1 at the end.

```crystal
session.on_event do |event|
  if event.is_a?(Llamero::Native::TrainingValidationEvent)
    puts "validation @#{event.iteration}: #{event.validation_loss.round(3)}"
  end
end
```

## Hyperparameter guidance (`AdapterTrainingConfig`)

| Goal | Settings |
|---|---|
| Memorize a small fact set (a manual section, a spec sheet) | `learning_rate = 1e-4`, `iterations = 200..400`, defaults otherwise |
| Style/tone adapter | `learning_rate = 2e-5..5e-5`, `iterations = 400+`, more diverse data |
| Bigger dataset (hundreds of pairs) | default `learning_rate = 1e-5`, `iterations = 600+` |
| More capacity (model keeps failing to learn) | raise `rank` to 16, `num_layers` to 24 |

All fields with defaults: `rank = 8`, `scale = 10.0`, `num_layers = 16`,
`fine_tune_type = Lora` (or `Dora`), `iterations = 200`, `batch_size = 2`,
`learning_rate = 1e-5`, `steps_per_report = 10`, `steps_per_eval = 50`,
`validation_batches = 5`.

## Dataset details

- `TrainingDataset#add(prompt, completion)` rejects blank strings.
- The default chat template is **ChatML**, which matches Qwen-family models.
  For a model family with different special tokens, pass a custom format proc:

  ```crystal
  gemma_format = ->(pair : Llamero::Native::TrainingDataset::Pair, system : String?) : String {
    "<start_of_turn>user\n#{system}\n#{pair.prompt}<end_of_turn>\n" \
    "<start_of_turn>model\n#{pair.completion}<end_of_turn>"
  }
  dataset = Llamero::Native::TrainingDataset.new(format: gemma_format)
  ```

  Using the wrong template still trains (loss drops) but the adapter answers
  poorly at inference time. Match the template to the model family.
- llamero ships a worked example dataset about its own API:
  `training_data/llamero_api_qa.jsonl` (in a consumer project:
  `lib/llamero/training_data/llamero_api_qa.jsonl`) plus
  `examples/train_llamero_docs_adapter.cr` which trains a "llamero-docs"
  adapter from it. Load pair files with
  `Llamero::Native::TrainingDataset.from_pairs_jsonl(path)`.
- Already have mlx_lm-format data? Pass a directory containing `train.jsonl`
  (and optionally `valid.jsonl`) instead of a `TrainingDataset`:
  `session.train_adapter("name", Path["my/data/dir"], config)`.

## Large documents (the "1000-page manual" pattern)

`train_adapter` is the primitive, not the whole pipeline. For a large
document: chunk it into sections, generate question/answer pairs per section
(a cloud model via `Llamero::Client` or a larger local model works well as the
generator), accumulate them into one `TrainingDataset` (or several, one
adapter per major topic), then train. Verify with held-out questions the
generator did not produce.

## Errors and constraints

| Error / symptom | Cause | Fix |
|---|---|---|
| `SessionStateError: Model is not loaded` | Training before `load_model` | Load the model first |
| `AdapterTrainingError` "active adapters" | Training while an adapter is active | `session.deactivate_adapters` first — training requires the plain base model |
| `ArgumentError: Dataset directory ... has no train.jsonl` | Wrong directory passed | Point at the dir containing `train.jsonl`, or pass a `TrainingDataset` |
| Loss drops but model still answers wrong | Wrong chat template for the model family | See Dataset details above |
| Adapter answers ONLY exact dataset wording | Too few paraphrases | Add 2–4 phrasings per fact |
| Base model seems changed after training | It is not — verify | Training restores the model on success and failure; check `session.load_count == 1` |

A failed training run never kills the session: catch `AdapterTrainingError`
and keep chatting on the same resident model.
