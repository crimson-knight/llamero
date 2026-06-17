**Bottom Line**

`DIRECTIVE -> implementation` is the right SFT shape, and it directly fixes the v1 failure. I sampled `training_data/crystal/crystal_sft.jsonl`: 1,331 / 1,599 completions contain `# =>`, only 46 contain `def`, and only 65 contain `class`/`struct`/`module`. That is example-snippet data, not implementation data.

But v2 as written is necessary, not sufficient. It can make a better Crystal code generator. It will not by itself make a 1B “Haiku-level” at real coding unless you add contextual edits, compiler-error repair, tests/specs, multi-file project work, and the Llamero/tool-call corpus described in [development_docs/crystal_expert_and_agentic_corpus_plan.md](/Users/crimsonknight/open_source_coding_projects/llamero/development_docs/crystal_expert_and_agentic_corpus_plan.md:62).

**1. Structure**

Directive-to-implementation is correct for the foundation corpus. The risk is that “complete idiomatic implementation” will still become toy standalone snippets unless the prompt distribution looks like real work.

Big concerns:

- The “1B as good as Haiku” goal is unrealistic from code-only SFT. It may be plausible only for constrained Crystal tasks with compile/spec feedback, a 4B planner, and tool-call harness support.
- “Fully typed every method parameter and return” is good for public APIs, but forcing maximal typing everywhere can make code unidiomatic. Crystal often benefits from inferred locals and block types.
- The naming rule is too rigid. `is_`/`has_` booleans and `list_of_` collections are not generally idiomatic Crystal. Predicate methods should usually be `active?`, `empty?`, `valid?`; collections should usually be plural nouns like `users`, `orders_by_id`, `line_items`.
- “No single-letter names” should allow idiomatic exceptions: `io`, `id`, `db`, `i`, `x`, `y`, `e`, short block vars in tight transformations.
- “ONLY changed code” for contextual edits is under-specified. The model needs a fixed protocol: full replacement method, full file, unified diff, or structured `write_file` call. Ambiguity here will train unusable partials.

**2. Missing Categories**

The current category list is a good stdlib start, but not enough for real Crystal work.

Add:

- Specs: `crystal spec`, `describe/it`, temp files, exception expectations, fixtures.
- Compiler-error repair: given an error and code, produce the minimal fix.
- Multi-file project structure: `shard.yml`, `src/foo.cr`, `require`, namespaces, file naming.
- HTTP and network: `HTTP::Server`, `HTTP::Client`, `URI`, headers, JSON APIs.
- Process/env/shell: `Process.run`, env vars, exit statuses, avoiding unsafe backticks.
- Resource safety: `File.open` block form, `ensure`, cleanup, temp dirs.
- Performance: `String::Builder`, `Bytes`, `Slice`, streaming IO, avoiding repeated string concat.
- Security: path traversal, shell escaping, input validation.
- FFI/unsafe/light systems work: `LibC`, pointers, `Slice`, only with strong constraints.
- Real Llamero APIs: cloud clients, structured output, `MLXRuntime`, `ModelPool`, training datasets, adapters, storage root, `real_bridge?`.
- Agentic outputs: `read_file`, `write_file`, `look_up`, `run` JSON plans, not just raw code.

**3. Prompt Shape**

Use imperative prompts, but vary them aggressively:

- Greenfield: “Implement `InventoryLedger` with these behaviors...”
- Contextual edit: include existing code, exact target, and output contract.
- Failing spec: include spec failure, ask for the minimal implementation change.
- Compiler diagnostic: include Crystal error text and the relevant file.
- Multi-file: ask for structured tool calls writing exact paths.
- API-specific: “Use `Llamero::Native::ModelPool` to keep two models resident...”
- Constraint prompts: “Do not use deprecated APIs”, “preserve public method names”, “stream input instead of loading whole file”.

Avoid conversational prompts like “How would I...?” for SFT acting. Use those only in QA/version corpora.

**4. Completion Conventions**

For raw implementation SFT, completions should be code only: no Markdown fences, no explanation, no transcript comments.

Recommended conventions:

- Public method params and returns typed; locals typed only when useful.
- Include required `require` lines for standalone examples.
- Prefer small cohesive classes/modules over giant scripts.
- Use idiomatic Crystal predicates with `?`.
- Use `Enumerable`, `case`, nil narrowing, block forms, and early returns where natural.
- Keep most completions 30-180 lines; include some 200-500 line multi-file/tool-call examples, but do not let long generations dominate.
- For contextual edits, completion must follow one deterministic schema.
- For tool work, use the locked `AgenticPlan` JSON shape from the corpus plan, not prose.

**5. Latest Idiom + Version History**

Keep implementation examples latest-only. Version history must be a separate task mode with explicit prompts like “Answer this version-compatibility question.”

The current `version_facts.jsonl` is risky as-is. It uses unqualified symbols like `initialize`, `inspect`, `split`, and `blocking`. A deprecation gate that rejects raw symbol names will false-positive constantly. Deprecations must be scoped by owner/signature, e.g. `Time.self.monotonic`, not just `self.monotonic` or `split`.

Also, many version facts are compiler/internal path facts. Keep those low-weight or separate from app-code SFT, or the model may learn irrelevant internals instead of user-level Crystal.

**6. Additional Gates**

Beyond compile/format/deprecation/shape, add:

- Spec gate: generated tests or prompt-provided examples must pass with `crystal spec`.
- API-resolution gate: referenced constants/methods must exist in Crystal 1.20 docs/catalog.
- Scoped deprecation gate: owner + method + signature, not raw token matching.
- Context-adherence gate: contextual edits only change requested code.
- JSON schema gate for agentic/tool-call outputs.
- No-prose gate for code-only completions.
- Placeholder/stub gate: reject `TODO`, `NotImplemented`, fake hardcoded sample answers.
- Security/resource gate: reject unsafe shell interpolation, leaked file handles, broad `rescue` swallowing.
- Duplicate/template-similarity gate to prevent 10k near-identical tasks.
- Held-out real-task eval: compile, spec, and rubric score on tasks not generated from the same templates.

**7. Target Size**

For a serious v2 foundation, I would target roughly **30k-35k high-quality SFT pairs**, not 1.5k-5k. Smaller may improve style, but it will not plausibly hit the stated goal.

Concrete split:

- 7k core language/data: collections, strings, regex, parsing, enums, tuples, named tuples.
- 5k types/design: classes, structs, modules, generics, records, JSON serialization.
- 4k IO/CLI/process/env/filesystem.
- 3k error handling, nil safety, validation, resource cleanup.
- 3k concurrency/time/performance.
- 4k specs, compiler-error repair, failing-test repair.
- 3k contextual edits over existing code.
- 3k multi-file project/shard tasks.
- 3k Llamero-specific API/tool examples.
- 2k agentic `AgenticPlan` tool-call pairs.

Keep version facts separate: maybe **500-1,500** carefully scoped version QA pairs, not mixed into implementation SFT. Then use RL/GRPO on compile/spec/tool-call success. Without that last stage, v2 will likely produce nicer Crystal snippets, but not a dependable local coding actor.