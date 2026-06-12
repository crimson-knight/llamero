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

## Storage root

Default adapter storage is under `~/.llamero`. Apps that need app-owned AI
data set this at boot before creating runtimes or training:

```crystal
Llamero.storage_root = Path.home.join(".scribe")
```

`LLAMERO_HOME=/path/to/root` is the env alternative; programmatic wins. The
default `train_adapter` output becomes `Llamero::Storage.adapters_dir/<name>/`.

## Recipe: teach a model facts it cannot know (complete program)

```crystal
require "llamero"

# Train on a DENSE model (see "Choosing a base model" below).
runtime = Llamero::Native::MLXRuntime.new(model_id: "mlx-community/gemma-3-1b-it-4bit")
session = runtime.start_session
session.load_model

# 1. Golden dataset: prompt/completion pairs. Use several phrasings of each
#    fact so short training runs generalize beyond exact wording.
#    No format: needed — train_adapter automatically uses the model's own
#    chat template (or the right built-in) for datasets with the default.
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

# 3. Train. Streams live loss. Speed scales with model size: ~1 minute for
#    300 iterations on a 0.6B model, tens of minutes on a 2B-class model.
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

What happens: the artifact is written to
`Llamero::Storage.adapters_dir/lx900-manual/` (standard mlx_lm format:
`adapters.safetensors` + `adapter_config.json`), registered in
`runtime.adapters` under the name you gave, and the resident model is restored
— training never permanently changes it.

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

## Choosing a base model for training

**Use a dense model.** Verified working: `mlx-community/gemma-3-1b-it-4bit`
(3/3 on the shipped docs-adapter test) and `mlx-community/Qwen3-0.6B-4bit`.

**Known limitation:** Gemma 4 e-series models (`gemma-4-e2b-*`,
`gemma-4-E4B-*` — MatFormer-style elastic architectures) train to low loss
but the resulting adapter has **no effect at inference**. Do not debug your
dataset or hyperparameters if this happens — switch to a dense base model.
(Suspected train/inference path divergence in the upstream architecture
implementation; tracked in `development_docs/multimodal_roadmap.md`.)

You can still *run inference* on e-series models; the limitation is only
adapter training on them.

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
- **Chat templates are automatic.** When the dataset keeps the default
  format, `train_adapter` renders it through the model's **own** chat
  template (the Jinja `chat_template` shipped in the downloaded model files
  — the same template the bridge uses at inference), so training and
  inference formatting cannot drift apart. If the model directory is not on
  disk yet, or its template uses Jinja constructs the renderer cannot handle
  (some real templates do — they fall back silently and safely), llamero
  uses the built-in family template instead: `GEMMA` for Gemma models,
  `CHATML` (Qwen-style) otherwise. After training,
  `dataset.template_source` tells you which won: `"model-chat-template"` or
  `"built-in"`.
- Overrides remain available and skip the automatic path entirely:
  `format: Llamero::Native::TrainingDataset.template_for(model_id)` forces a
  built-in template, `Llamero::Native::TrainingDataset.template_from(model_dir)`
  builds a proc from any local model directory (returns nil when it cannot),
  and a custom proc handles anything else:

  ```crystal
  my_format = ->(pair : Llamero::Native::TrainingDataset::Pair, system : String?) : String {
    "<custom_user_token>#{pair.prompt}</custom_user_token>" \
    "<custom_model_token>#{pair.completion}</custom_model_token>"
  }
  dataset = Llamero::Native::TrainingDataset.new(format: my_format)
  ```

  Using the wrong template still trains (loss drops) but the adapter answers
  poorly at inference time.
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
| Loss drops but adapter has NO effect at all | Gemma 4 e-series base (e2b/e4b) | Train on a dense model: `gemma-3-1b-it-4bit` |
| Adapter answers ONLY exact dataset wording | Too few paraphrases | Add 2–4 phrasings per fact |
| Base model seems changed after training | It is not — verify | Training restores the model on success and failure; check `session.load_count == 1` |

A failed training run never kills the session: catch `AdapterTrainingError`
and keep chatting on the same resident model.
