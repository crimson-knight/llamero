# Round 3b adapter application probe

- Filter: `amber-v2@0.2.0` (`683d65226b3f328f`)
- Model: `mlx-community/gemma-3-4b-it-4bit@93724907d4ed1745d2fe50baadf3b0b01a65abf2`; weights SHA256 `94d3d701367d78584a9334ca00672b1c86e4aefa6a94167556c0485381e74af3`
- Prompts: 6 verbatim training rows (2 each row tenancy, raw SQL, schema tenancy), each run under both system-prompt labels.
- System prompts byte-equal: `true`; both literals were checked against their source files.
- Generation: greedy (`temperature=0`), `max_tokens=400`.
- Chain activation events: 2/2; names=amber-v2-stage-0;fused=true;cumulative=true;remaps=amber-v2-stage-0:identity; names=amber-v2-stage-1;fused=true;cumulative=true;remaps=amber-v2-stage-1:identity
- Full-chain unfused activation supported: `false`; the public chain path always cumulatively fuses stages, and the bridge rejects live multi-adapter stacks.
- Fused logits changed above 1e-5 mean absolute delta: 12/12; mean delta range 2.502936399681141–3.4719274547497756.
- Fused answers differed from base: 12/12. Training-symbol hits: 0/26; complete marker sets: 0/12.

| System prompt | Topic | Training row | Base marker hits | Fused marker hits | Mean absolute logit delta | Top-1 changed | Answers identical |
| --- | --- | --- | ---: | ---: | ---: | --- | --- |
| eval | row_tenancy | row_tenancy_declaration | 0/2 | 0/2 | 2.72283926 | true | false |
| eval | row_tenancy | row_tenancy_search | 0/3 | 0/3 | 3.21063282 | true | false |
| eval | raw_sql | raw_sql_find_by_sql | 0/2 | 0/2 | 3.36283599 | true | false |
| eval | raw_sql | raw_sql_count_by_sql | 0/2 | 0/2 | 3.18569016 | true | false |
| eval | schema_tenancy | schema_tenancy_switch | 0/2 | 0/2 | 3.47192745 | false | false |
| eval | schema_tenancy | schema_tenancy_excluded | 0/2 | 0/2 | 2.5029364 | true | false |
| training | row_tenancy | row_tenancy_declaration | 0/2 | 0/2 | 2.72283926 | true | false |
| training | row_tenancy | row_tenancy_search | 0/3 | 0/3 | 3.21063282 | true | false |
| training | raw_sql | raw_sql_find_by_sql | 0/2 | 0/2 | 3.36283599 | true | false |
| training | raw_sql | raw_sql_count_by_sql | 0/2 | 0/2 | 3.18569016 | true | false |
| training | schema_tenancy | schema_tenancy_switch | 0/2 | 0/2 | 3.47192745 | false | false |
| training | schema_tenancy | schema_tenancy_excluded | 0/2 | 0/2 | 2.5029364 | true | false |

Raw generations, expected completions, top-five tokens, and per-prompt logits are in `round3b-adapter-probe.jsonl`.
