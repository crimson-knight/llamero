# Grant filter rubric (DRAFT 2, awaiting Seth's approval)

Status: proposed 2026-10-05. No training or eval runs until Seth approves this
page. Numbers in **bold** are proposed defaults; edit them in place to change them.

## Scope

The first subject is the most basic Grant skill: **writing a correct Grant
model.** Multi-tenancy and raw SQL are out of scope until the basics pass.

The model under training is a 4B model. Each question is answered in one turn
with code only: no tools, no follow-up turns, no running or compiling its own
code. The harness does all compiling and running.

## Why the old scoring is replaced

Round 3b's scoring could be won without learning Grant:

- **"Compiles" did not mean "uses Grant."** The judge only type-checked the
  answer.
- **Required symbols included our own example class names** (`TenantInvoice`),
  which rewarded copying training boilerplate.
- **Answers were never run.**
- **One mixed corpus covered six features at once**, so no one could tell
  which examples taught what.

## Definitions

| Term | Meaning |
|---|---|
| **Grant model** | One Crystal class that inherits `Grant::Base` and declares `connection`, `table`, a primary-key `column`, and its other columns, as in Grant's README. |
| **Stage** | One Grant skill with its own training examples and its own held-out questions. Stages are taught in order, one at a time. |
| **Training example** | One question-and-answer pair. The answer compiles against pinned Grant, uses only APIs that exist in Grant's source, and passes its own behavior check. |
| **Held-out question** | An eval question that never appears in training. Its model, table, and column names differ from every training example in its stage, and no training prompt shares 80% or more of its words. |
| **Stage API** | The public Grant names a stage teaches, taken from Grant's source at the pinned commit. Never a class name we invented for an example. |
| **Invented API** | Any `Grant::` constant, model macro, or method on a Grant model that does not exist in pinned Grant. |
| **Copied answer** | An answer that shares **50%** or more of its code lines with any single training answer. |
| **Baseline** | The installed filter (amber-v2 0.1.0) and the base model with no filter, scored on the same questions. |

## How one answer is scored

Each level counts only if every level above it passed.

| Level | Name | Passes when |
|---|---|---|
| L1 | Compiles | The answer builds against pinned Grant with the harness's SQLite connection. |
| L2 | Uses Grant correctly | Every required stage API appears, and the answer contains no invented API. |
| L3 | Works | The harness runs it against SQLite and the question's behavior check passes. |

Each answer also gets one flag that is not a score: **Copied**.

**Headline number per stage: L3 rate on held-out questions.**

### What the harness provides for every answer

- `require "grant"`, `require "grant/adapter/sqlite"`, and a connection
  registered as `primary` on a fresh SQLite file.
- `Model.migrator.drop_and_create` for each model the question names, run
  before the behavior check.

## The stages

| Order | Stage | Stage API | Example behavior check | Held-out questions |
|---|---|---|---|---|
| 1 | **Define a model** from a plain-English table description | `Grant::Base`, `connection`, `table`, `column`, `primary: true`, nilable types, defaults, `timestamps` | Create the table, save one record, read it back: every column round-trips with the right type, nilable columns accept `nil`, defaults apply, and timestamps are set. | **15** |
| 2 | Create, read, update, delete | `create`, `create!`, `save`, `find`, `find_by`, `where`, `order`, `limit`, `update`, `destroy` | Seeded rows; the answer's code returns or changes exactly the expected rows. | **15** |
| 3 | Validations | `validates_presence_of`, `validates_uniqueness_of`, `validates_length_of`, `validates_numericality_of`, `validate` | Invalid record: `save` returns false and `errors` names the field. Valid record saves. | **12** |
| 4 | Associations | `belongs_to`, `has_many`, `has_one`, `dependent:` | Parent and children saved; each side of the association loads the other. | **12** |
| 5 | Scopes and callbacks | `scope`, `before_save`, `after_create`, `before_destroy` | The scope returns only matching rows; the callback's side effect happened. | **10** |

Tenancy, raw SQL, enums, encryption, and the rest of the parity surface come
after stage 5 passes.

## Pass bar for a stage

A new filter passes a stage when all of these hold:

1. Held-out L3 rate is at least **60%** and at least **25 points** above the
   better of the two baselines.
2. Copied answers make up at most **10%** of the L3 passes.
3. Amber regression: no more than **1** fewer L1 passes than baseline, out of
   **20** Amber questions.
4. Every earlier stage drops by at most **1** held-out question.

A filter is promoted to default only when every stage trained so far passes.

## How each stage grows

Each stage is trained at **25**, then **75** examples, so we see what adding
examples changes. A stage moves on once it passes. If both sizes fail, Opus
diagnoses why before anyone writes more examples. The first thing measured is
the base model with no filter on stage 1, so we know where it starts.

## Who does what

- **Opus:** writes each stage's held-out questions and behavior checks first,
  before any training examples exist. Also reads results and diagnoses failures.
- **Sonnet 5.5:** writes training examples to this page's definitions, runs
  L1/L2/L3 on each one, and scores eval runs.
- **Luna:** the training and eval harness code (the L3 runner, the
  invented-API check, the copied-answer flag).

## Compute rules

The Mac has 32 GB of memory and runs other apps. No run's peak memory has been
measured yet.

1. **Measure first.** One 25-example training run and one eval run, each under
   `/usr/bin/time -l`, record peak memory on this page.
2. **One model job at a time.** Training and eval never overlap.
3. **Start gate:** a job starts only when at least **(measured peak + 4 GB)**
   is free. Otherwise it waits and retries every **15 minutes**.
4. **One eval run per filter.** Round 3b's repeat runs agreed 42 of 42 at
   temperature 0.
5. Writing training examples and L1/L2/L3 checks on them do not load the model,
   so they run anytime.
