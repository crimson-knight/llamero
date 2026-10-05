# Grant filter rubric (DRAFT, awaiting Seth's approval)

Status: proposed 2026-10-05. No training or eval runs until Seth approves this
page. Numbers in **bold** are proposed defaults; edit them in place to change them.

## Why this exists

Round 3b showed that today's scoring can be won without learning Grant:

- **"Compiles" does not mean "uses Grant."** The judge only type-checks the
  answer. Code that never touches the feature can still pass.
- **Required symbols include our own example class names.** `TenantInvoice`
  is a training-corpus class, not a Grant API. 0.2.4 scored 17/37 compiles
  largely by copying that boilerplate.
- **Answers are never run.** Nothing checks that a tenant-scoped query
  actually returns only that tenant's rows.
- **The Amber regression check has five questions**, so one answer changes
  the result by 20 points.
- **One mixed corpus of 84 examples covers six features at once**, so we can't
  tell which examples taught what.

## Definitions

| Term | Meaning |
|---|---|
| **Feature slice** | One Grant feature with its own training examples and its own held-out questions, e.g. "row tenancy: `multitenant` + `Grant::Tenant.with`". |
| **Training example** | One question-and-answer pair. The answer is Crystal that compiles against pinned Grant, uses only APIs that exist in Grant's source, and passes the example's behavior check. |
| **Held-out question** | An eval question that never appears in training. It uses different model, table, and column names from every training example in its slice, and no training prompt shares 80% or more of its words. |
| **Feature API** | The public Grant names the slice is about, taken from Grant's source (e.g. `multitenant`, `Grant::Tenant.with`, `Grant::NoTenantError`). Never a class name we invented for an example. |
| **Invented API** | Any `Grant::` constant, or any method called on a Grant model or class, that does not exist in pinned Grant. |
| **Copied answer** | An answer that shares **50%** or more of its code lines with any single training answer. |
| **Baseline** | The installed filter, amber-v2 0.1.0, scored on the same questions with the same activation path. |

## How one answer is scored

Each level counts only if every level above it passed.

| Level | Name | Passes when |
|---|---|---|
| L1 | Compiles | The code builds against pinned Amber + Grant. |
| L2 | Uses the feature | Every required feature API for the question appears, and the answer contains no invented API. |
| L3 | Works | The answer runs against SQLite (Postgres for schema tenancy), and the question's behavior check passes. Example: two tenants' rows exist, and the query returns only the active tenant's rows. |

Each answer also gets one flag that is not a score: **Copied** (see Definitions).

**Headline number per slice: L3 rate on held-out questions.** L1 and L2 are
reported so we can see where answers fail.

## Pass bar for a slice

A new filter passes a slice when all of these hold:

1. Held-out L3 rate is at least **60%** and at least **25 points** above baseline.
2. Copied answers make up at most **10%** of the L3 passes.
3. Amber regression: no more than **1** fewer L1 passes than baseline, out of
   **20** questions (grown from today's 5).
4. Every slice that passed earlier drops by at most **1** held-out question.

A filter is promoted to default only when every slice trained so far passes.

## Incremental plan

Each slice is trained and scored on its own first, then added to the
cumulative filter.

| Order | Slice | Feature API | Held-out questions |
|---|---|---|---|
| 1 | Row tenancy | `multitenant`, `Grant::Tenant.with`, `unscoped`, `NoTenantError`, `TenantMismatchError` | **12** |
| 2 | Schema tenancy | `Grant::SchemaTenant.with`, `schema_tenant_excluded`, `create_schema`, `create_tables`, `drop_schema`, `list_schemas` | **12** |
| 3 | Raw SQL | `find_by_sql`, `count_by_sql`, `connection.exec_query`, `select_all`, `select_value`, `ScopedRawSqlError` | **12** |
| 4 | Tenant request pipe | Amber pipe + `Grant::Tenant.with` / `SchemaTenant.with` around `call_next` | **8** |
| 5 | Apartment migration | Apartment-to-Grant mappings from the multi-tenancy guide | **8** |

Every slice is trained at two sizes, **25** and **75** examples, so we see
whether adding examples moves its score. A slice moves on only after it
passes or after both sizes fail. When both fail, Opus diagnoses the failure
before anyone writes more examples.

## Who does what

- **Opus:** writes each slice's held-out questions and behavior checks first,
  before any training examples exist. Also reads results and diagnoses failures.
- **Sonnet 5.5:** writes training examples to this page's definitions, runs
  the L1/L2/L3 checks on them, and scores eval runs.
- **Luna:** the native training and eval harness code (MLX bridge, filter
  activation, the new L3 runner).

## Compute rules

The Mac has 32 GB of memory and runs other apps. No run's peak memory has been
measured yet.

1. **Measure first.** One 25-example slice training and one eval run, each under
   `/usr/bin/time -l`, record peak memory in this page.
2. **One MLX job at a time.** Training and eval never overlap.
3. **Start gate:** a job starts only when `memory_pressure` reports at least
   **(measured peak + 4 GB)** free. Otherwise it waits and retries every
   **15 minutes**.
4. **One eval run per filter.** Round 3b's repeated runs agreed 42 of 42 at
   temperature 0, so a second run adds nothing.
5. L3 checks use SQLite where possible; Postgres runs only for schema tenancy.

## What changes in the eval harness

- Feature-slice question files: `grant_eval_<slice>.jsonl`, one per slice,
  each question carrying `required_feature_api` and a `behavior_check`.
- `required_symbols` loses every example class name.
- An invented-API check against Grant's public API, built from Grant's
  source at the pinned commit.
- The L3 runner and the copied-answer flag.
- The Amber regression cohort grows to 20 questions.
