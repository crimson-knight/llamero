# Round 3b aggregate results

Greedy evaluation used temperature 0 and max_tokens 600 over 37 held-out Grant
questions plus the same five Amber regression questions. Each configuration
ran twice; within-configuration answers and scores were identical on 42/42
questions.

| Filter | Grant compile | Grant complete cases | Grant symbol hits | Amber compile | Amber complete cases | Amber symbol hits |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Installed 0.1.0 | 7/37 | 0/37 | 6/107 | 3/5 | 1/5 | 6/16 |
| 0.2.0 | 3/37 | 1/37 | 16/107 | 0/5 | 0/5 | 6/16 |
| 0.2.1 completion-only | 2/37 | 2/37 | 15/107 | 0/5 | 0/5 | 7/16 |

The complete per-topic and per-run breakdown follows.

| Run | Cohort | Topic | Questions | Compile | Complete cases | Symbol hits |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| round3b-baseline-0.1.0-run-1 | amber_regression | controllers | 1 | 1/1 (100.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-baseline-0.1.0-run-1 | amber_regression | jobs | 1 | 1/1 (100.0%) | 1/1 (100.0%) | 4/4 (100.0%) |
| round3b-baseline-0.1.0-run-1 | amber_regression | routing | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 0/3 (0.0%) |
| round3b-baseline-0.1.0-run-1 | amber_regression | schema | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 0/3 (0.0%) |
| round3b-baseline-0.1.0-run-1 | amber_regression | websockets | 1 | 1/1 (100.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-baseline-0.1.0-run-1 | grant_heldout | amber_tenant_pipe | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 1/18 (5.6%) |
| round3b-baseline-0.1.0-run-1 | grant_heldout | apartment_migration | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 0/13 (0.0%) |
| round3b-baseline-0.1.0-run-1 | grant_heldout | parity | 6 | 2/6 (33.3%) | 0/6 (0.0%) | 3/19 (15.8%) |
| round3b-baseline-0.1.0-run-1 | grant_heldout | raw_sql | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 1/21 (4.8%) |
| round3b-baseline-0.1.0-run-1 | grant_heldout | row_tenancy | 7 | 2/7 (28.6%) | 0/7 (0.0%) | 0/18 (0.0%) |
| round3b-baseline-0.1.0-run-1 | grant_heldout | schema_tenancy | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 1/18 (5.6%) |
| round3b-baseline-0.1.0-run-2 | amber_regression | controllers | 1 | 1/1 (100.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-baseline-0.1.0-run-2 | amber_regression | jobs | 1 | 1/1 (100.0%) | 1/1 (100.0%) | 4/4 (100.0%) |
| round3b-baseline-0.1.0-run-2 | amber_regression | routing | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 0/3 (0.0%) |
| round3b-baseline-0.1.0-run-2 | amber_regression | schema | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 0/3 (0.0%) |
| round3b-baseline-0.1.0-run-2 | amber_regression | websockets | 1 | 1/1 (100.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-baseline-0.1.0-run-2 | grant_heldout | amber_tenant_pipe | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 1/18 (5.6%) |
| round3b-baseline-0.1.0-run-2 | grant_heldout | apartment_migration | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 0/13 (0.0%) |
| round3b-baseline-0.1.0-run-2 | grant_heldout | parity | 6 | 2/6 (33.3%) | 0/6 (0.0%) | 3/19 (15.8%) |
| round3b-baseline-0.1.0-run-2 | grant_heldout | raw_sql | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 1/21 (4.8%) |
| round3b-baseline-0.1.0-run-2 | grant_heldout | row_tenancy | 7 | 2/7 (28.6%) | 0/7 (0.0%) | 0/18 (0.0%) |
| round3b-baseline-0.1.0-run-2 | grant_heldout | schema_tenancy | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 1/18 (5.6%) |
| round3b-baseline-0.2.0-run-1 | amber_regression | controllers | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-baseline-0.2.0-run-1 | amber_regression | jobs | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/4 (50.0%) |
| round3b-baseline-0.2.0-run-1 | amber_regression | routing | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-baseline-0.2.0-run-1 | amber_regression | schema | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-baseline-0.2.0-run-1 | amber_regression | websockets | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 0/3 (0.0%) |
| round3b-baseline-0.2.0-run-1 | grant_heldout | amber_tenant_pipe | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 0/18 (0.0%) |
| round3b-baseline-0.2.0-run-1 | grant_heldout | apartment_migration | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 0/13 (0.0%) |
| round3b-baseline-0.2.0-run-1 | grant_heldout | parity | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 5/19 (26.3%) |
| round3b-baseline-0.2.0-run-1 | grant_heldout | raw_sql | 6 | 2/6 (33.3%) | 1/6 (16.7%) | 9/21 (42.9%) |
| round3b-baseline-0.2.0-run-1 | grant_heldout | row_tenancy | 7 | 0/7 (0.0%) | 0/7 (0.0%) | 1/18 (5.6%) |
| round3b-baseline-0.2.0-run-1 | grant_heldout | schema_tenancy | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 1/18 (5.6%) |
| round3b-baseline-0.2.0-run-2 | amber_regression | controllers | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-baseline-0.2.0-run-2 | amber_regression | jobs | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/4 (50.0%) |
| round3b-baseline-0.2.0-run-2 | amber_regression | routing | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-baseline-0.2.0-run-2 | amber_regression | schema | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-baseline-0.2.0-run-2 | amber_regression | websockets | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 0/3 (0.0%) |
| round3b-baseline-0.2.0-run-2 | grant_heldout | amber_tenant_pipe | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 0/18 (0.0%) |
| round3b-baseline-0.2.0-run-2 | grant_heldout | apartment_migration | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 0/13 (0.0%) |
| round3b-baseline-0.2.0-run-2 | grant_heldout | parity | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 5/19 (26.3%) |
| round3b-baseline-0.2.0-run-2 | grant_heldout | raw_sql | 6 | 2/6 (33.3%) | 1/6 (16.7%) | 9/21 (42.9%) |
| round3b-baseline-0.2.0-run-2 | grant_heldout | row_tenancy | 7 | 0/7 (0.0%) | 0/7 (0.0%) | 1/18 (5.6%) |
| round3b-baseline-0.2.0-run-2 | grant_heldout | schema_tenancy | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 1/18 (5.6%) |
| round3b-0.2.1-completion-only-run-1 | amber_regression | controllers | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-0.2.1-completion-only-run-1 | amber_regression | jobs | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/4 (50.0%) |
| round3b-0.2.1-completion-only-run-1 | amber_regression | routing | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-0.2.1-completion-only-run-1 | amber_regression | schema | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-0.2.1-completion-only-run-1 | amber_regression | websockets | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 0/3 (0.0%) |
| round3b-0.2.1-completion-only-run-1 | grant_heldout | amber_tenant_pipe | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 0/18 (0.0%) |
| round3b-0.2.1-completion-only-run-1 | grant_heldout | apartment_migration | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 0/13 (0.0%) |
| round3b-0.2.1-completion-only-run-1 | grant_heldout | parity | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 6/19 (31.6%) |
| round3b-0.2.1-completion-only-run-1 | grant_heldout | raw_sql | 6 | 0/6 (0.0%) | 2/6 (33.3%) | 8/21 (38.1%) |
| round3b-0.2.1-completion-only-run-1 | grant_heldout | row_tenancy | 7 | 0/7 (0.0%) | 0/7 (0.0%) | 0/18 (0.0%) |
| round3b-0.2.1-completion-only-run-1 | grant_heldout | schema_tenancy | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 1/18 (5.6%) |
| round3b-0.2.1-completion-only-run-2 | amber_regression | controllers | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-0.2.1-completion-only-run-2 | amber_regression | jobs | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/4 (50.0%) |
| round3b-0.2.1-completion-only-run-2 | amber_regression | routing | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-0.2.1-completion-only-run-2 | amber_regression | schema | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-0.2.1-completion-only-run-2 | amber_regression | websockets | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 0/3 (0.0%) |
| round3b-0.2.1-completion-only-run-2 | grant_heldout | amber_tenant_pipe | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 0/18 (0.0%) |
| round3b-0.2.1-completion-only-run-2 | grant_heldout | apartment_migration | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 0/13 (0.0%) |
| round3b-0.2.1-completion-only-run-2 | grant_heldout | parity | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 6/19 (31.6%) |
| round3b-0.2.1-completion-only-run-2 | grant_heldout | raw_sql | 6 | 0/6 (0.0%) | 2/6 (33.3%) | 8/21 (38.1%) |
| round3b-0.2.1-completion-only-run-2 | grant_heldout | row_tenancy | 7 | 0/7 (0.0%) | 0/7 (0.0%) | 0/18 (0.0%) |
| round3b-0.2.1-completion-only-run-2 | grant_heldout | schema_tenancy | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 1/18 (5.6%) |
run agreement round3b-0.2.1-completion-only (round3b-0.2.1-completion-only-run-1 vs round3b-0.2.1-completion-only-run-2): answers 42/42 (100.0%); compile+symbols 42/42 (100.0%)
run agreement round3b-baseline-0.1.0 (round3b-baseline-0.1.0-run-1 vs round3b-baseline-0.1.0-run-2): answers 42/42 (100.0%); compile+symbols 42/42 (100.0%)
run agreement round3b-baseline-0.2.0 (round3b-baseline-0.2.0-run-1 vs round3b-baseline-0.2.0-run-2): answers 42/42 (100.0%); compile+symbols 42/42 (100.0%)
