# Grant filter rubric (DRAFT 3, awaiting Seth's approval)

Status: proposed 2026-10-05. No training or eval runs until Seth approves this
page. Numbers in **bold** are proposed defaults; edit them in place to change them.

## The bar

**A stage passes when at least 95% of its held-out questions are fully correct
on the first try.** First try means one answer per question, temperature 0, no
retries, no repair loop, no second sample.

"Fully correct" means the answer passes all four levels below. An answer that
works but breaks house conventions is a failure.

Anything below the bar is reported as **proof of concept, not passing**, with
the measured rate and the list of failed questions. The bar is never lowered
to fit a result.

## Values this rubric enforces, and where they come from

| Value | Source |
|---|---|
| Clean compile means GREEN: `crystal-alpha`, zero errors **and** zero warnings | crystal-conventions skill, rule 3 |
| Zero MAJOR items from the house review rubric; an open MAJOR does not ship | `crystal-conventions/references/review-rubric.md` |
| AED names: singular models, attributes that state their purpose, file path mirrors the class | crystal-conventions rule 7; AED |
| Code is checked against Grant's real API at the pinned commit | crystal-conventions "Definition of done"; Grant API facts |
| Every training answer is read before it is used; row count is not quality | memory: read-completions-before-fusing-a-corpus |
| A gate fails closed: a missing subject, a missing tool, or zero measured questions is a FAIL | memory: gate-vacuous-pass-epidemic-2026-08-02 |
| Finding a name in the text is not proof the code is correct | same memory, "presence is not value" |
| Every status claim states its scope and denominator | memory: feedback-scoped-completion-claims |
| Every dependency, model, and toolchain is pinned to an exact version and hash | CLAUDE.md standing rule |

## Scope

The first subject is the most basic Grant skill: **writing a correct Grant
model.** Multi-tenancy and raw SQL are out of scope until the basics pass.

The model is a 4B model answering in one turn with code only. It does not use
tools, run code, or see compiler output. The harness does all compiling and
running.

## Definitions

| Term | Meaning |
|---|---|
| **Grant model** | One Crystal class that inherits `Grant::Base` and declares `connection`, `table`, an `Int64` primary-key `column`, and its other columns, as in Grant's README. |
| **Stage** | One Grant skill with its own training examples and its own held-out questions. Stages are taught in order. |
| **Training example** | One question-and-answer pair whose answer passes all four levels. Opus reads every training answer before it is used. |
| **Held-out question** | An eval question that never appears in training. Its model, table, and column names differ from every training example in its stage, and no training prompt shares 80% or more of its words. |
| **Invented API** | Any `Grant::` constant, model macro, or method on a Grant model that does not exist in pinned Grant. |
| **Baseline** | The base model with no filter, and the installed filter (amber-v2 0.1.0), scored on the same questions. |

## How one answer is scored

An answer is fully correct only when it passes all four levels.

| Level | Name | Passes when |
|---|---|---|
| L1 | GREEN | `crystal-alpha build --no-codegen` reports zero errors and zero warnings, and `crystal-alpha tool format --check` accepts it unchanged. |
| L2 | Correct Grant | Checked on the compiled model, not by searching the text: the class name, table, primary key, and every column's name, type, nilability, and default match the question. No invented API. |
| L3 | Works | The harness runs it against SQLite and the question's behavior check passes. |
| L4 | House conventions | Zero MAJOR items from the house review rubric. For a model this means: singular class name, attributes that state their purpose (no bare `name`), the first line names the file as `src/models/<snake_case_class>.cr`, no `not_nil!` or silencing `.as(T)`, no `puts`/`p`/`pp`, no constant as a `column` default, Int64 ids, `Time` for timestamps. |

Each failed answer is logged with the first level it failed and the compiler,
behavior-check, or rubric message, so every failure has a stated reason.

### The harness provides

- `require "grant"`, `require "grant/adapter/sqlite"`, and a connection
  registered as `primary` on a fresh SQLite file.
- `Model.migrator.drop_and_create` for each model the question names.

### The harness fails closed

A run is invalid, not passing, when: the measured question count differs from
the question file's count; any question lacks a behavior check; the toolchain
or Grant commit differs from the pin; or any level's checker errors. An invalid
run is rerun after the fault is fixed.

## The stages

| Order | Stage | Grant API | Example behavior check |
|---|---|---|---|
| 1 | **Define a model** from a plain-English table description | `Grant::Base`, `connection`, `table`, `column`, `primary: true`, nilable types, defaults, `timestamps` | Create the table, save one record, read it back: every column round-trips with the right type, nilable columns accept `nil`, defaults apply, timestamps are set. |
| 2 | Create, read, update, delete | `create`, `create!`, `save`, `find`, `find_by`, `where`, `order`, `limit`, `update`, `destroy` | Seeded rows; the answer returns or changes exactly the expected rows. |
| 3 | Validations | `validates_presence_of`, `validates_uniqueness_of`, `validates_length_of`, `validates_numericality_of`, `validate` | Invalid record: `save` returns false and `errors` names the field. Valid record saves. |
| 4 | Associations | `belongs_to`, `has_many`, `has_one`, `dependent:` | Parent and children saved; each side of the association loads the other. |
| 5 | Scopes and callbacks | `scope`, `before_save`, `after_create`, `before_destroy` | The scope returns only matching rows; the callback's side effect happened. |

Each stage has **40** held-out questions, so 95% means at least **38 of 40**.

Tenancy, raw SQL, enums, encryption, and the rest of the parity surface come
after stage 5 passes.

## Pass bar for a stage

A new filter passes a stage when all of these hold:

1. At least **38 of 40** held-out questions are fully correct on the first try.
2. Every earlier stage still meets its own 95% bar.
3. The Amber regression set (**20** questions) loses **zero** fully correct
   answers against the installed filter.
4. 100% of the stage's training examples pass all four levels before training.

A filter becomes the default only when every stage trained so far passes.

## How each stage grows

Training sizes go **25**, **75**, **200** examples. The first measurement is
the base model with no filter on stage 1, so we know where it starts. After
each size, Opus reads every failed answer and groups the failures by cause
before more examples are written: the next batch targets the measured causes.
If a stage stops improving between sizes, Opus reports the measured ceiling
and the failure groups to Seth.

## Who does what

- **Opus:** writes each stage's held-out questions and behavior checks before
  any training examples exist, reads every training answer, reads every failed
  eval answer, and diagnoses failures.
- **Sonnet 5.5:** writes training examples to this page's definitions and runs
  L1 to L4 on each one.
- **Luna:** the harness code (the L2 compiled-model check, the L3 runner, the
  L4 rubric checks, fail-closed run validation).

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
5. Writing training examples and checking them with L1 to L4 do not load the
   model, so they run anytime.
