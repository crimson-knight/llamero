# Round 3b: train/serve fix, 0.2.3 and 0.2.4

Greedy evaluation, temperature 0, max_tokens 600, 37 held-out Grant questions
plus the five Amber regression questions. "Fused final stage" is the old
`activate_filter` path; "live final stage" is the fixed path (earlier stages
fused as in training, the final stage as live LoRA layers). 0.2.3 and 0.2.4
ran twice each; both pairs agreed on 42/42 answers and scores. The two
live-final rescoring runs of 0.1.0 and 0.2.1 ran once each.

| Filter | Activation | Grant compile | Grant complete | Grant symbols | Amber compile | Amber complete | Amber symbols |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.1.0 (installed) | fused final stage | 7/37 | 0/37 | 6/107 | 3/5 | 1/5 | 6/16 |
| 0.2.0 | fused final stage | 3/37 | 1/37 | 16/107 | 0/5 | 0/5 | 6/16 |
| 0.2.1 completion-only | fused final stage | 2/37 | 2/37 | 15/107 | 0/5 | 0/5 | 7/16 |
| 0.1.0 (installed) | live final stage | 5/37 | 0/37 | 13/107 | 2/5 | 0/5 | 7/16 |
| 0.2.1 completion-only | live final stage | 9/37 | 1/37 | 28/107 | 1/5 | 1/5 | 9/16 |
| 0.2.3 (0.1.0 seed + syntax 200 + usage 400) | live final stage | 9/37 | 2/37 | 30/107 | 1/5 | 0/5 | 7/16 |
| 0.2.4 (0.1.0 seed + syntax 200 + usage 150) | live final stage | 17/37 | 0/37 | 15/107 | 1/5 | 0/5 | 8/16 |

Training-row loss (84 Grant rows, completion-only) through the fixed path
equals the training probe: 0.2091 for 0.2.1, 0.1148 for 0.2.3 (0.2.4 training
reported 0.3456). See `round3b-train-serve-loss.md`.

Reading: the fix makes the adapters' behavior reach inference (0.2.1 goes
from 2/37 to 9/37 compiled and 15 to 28 symbol hits with no retraining). It
does not by itself meet the promotion gate. 0.2.4's 17/37 compile rate comes
mostly from reproducing the training corpus's `TenantInvoice` boilerplate:
its symbol hits fell to 15/107 and no answer has every required symbol. The
Amber regression cohort fell from 3/5 to 1/5 in every Grant-trained filter;
with five questions a one- or two-question swing is within noise, but it has
not recovered. Neither 0.2.3 nor 0.2.4 is proposed as the default.

## Per-topic breakdown

| Run | Cohort | Topic | Questions | Compile | Complete cases | Symbol hits |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| round3b-0.2.1-live-final-run-1 | amber_regression | controllers | 1 | 1/1 (100.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-0.2.1-live-final-run-1 | amber_regression | jobs | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 3/4 (75.0%) |
| round3b-0.2.1-live-final-run-1 | amber_regression | routing | 1 | 0/1 (0.0%) | 1/1 (100.0%) | 3/3 (100.0%) |
| round3b-0.2.1-live-final-run-1 | amber_regression | schema | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-0.2.1-live-final-run-1 | amber_regression | websockets | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 0/3 (0.0%) |
| round3b-0.2.1-live-final-run-1 | grant_heldout | amber_tenant_pipe | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 5/18 (27.8%) |
| round3b-0.2.1-live-final-run-1 | grant_heldout | apartment_migration | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 2/13 (15.4%) |
| round3b-0.2.1-live-final-run-1 | grant_heldout | parity | 6 | 2/6 (33.3%) | 0/6 (0.0%) | 6/19 (31.6%) |
| round3b-0.2.1-live-final-run-1 | grant_heldout | raw_sql | 6 | 2/6 (33.3%) | 0/6 (0.0%) | 4/21 (19.0%) |
| round3b-0.2.1-live-final-run-1 | grant_heldout | row_tenancy | 7 | 1/7 (14.3%) | 1/7 (14.3%) | 6/18 (33.3%) |
| round3b-0.2.1-live-final-run-1 | grant_heldout | schema_tenancy | 6 | 3/6 (50.0%) | 0/6 (0.0%) | 5/18 (27.8%) |
| round3b-0.1.0-live-final-run-1 | amber_regression | controllers | 1 | 1/1 (100.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-0.1.0-live-final-run-1 | amber_regression | jobs | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/4 (50.0%) |
| round3b-0.1.0-live-final-run-1 | amber_regression | routing | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 0/3 (0.0%) |
| round3b-0.1.0-live-final-run-1 | amber_regression | schema | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-0.1.0-live-final-run-1 | amber_regression | websockets | 1 | 1/1 (100.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-0.1.0-live-final-run-1 | grant_heldout | amber_tenant_pipe | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 2/18 (11.1%) |
| round3b-0.1.0-live-final-run-1 | grant_heldout | apartment_migration | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 0/13 (0.0%) |
| round3b-0.1.0-live-final-run-1 | grant_heldout | parity | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 6/19 (31.6%) |
| round3b-0.1.0-live-final-run-1 | grant_heldout | raw_sql | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 4/21 (19.0%) |
| round3b-0.1.0-live-final-run-1 | grant_heldout | row_tenancy | 7 | 0/7 (0.0%) | 0/7 (0.0%) | 0/18 (0.0%) |
| round3b-0.1.0-live-final-run-1 | grant_heldout | schema_tenancy | 6 | 2/6 (33.3%) | 0/6 (0.0%) | 1/18 (5.6%) |
| round3b-0.2.3-run-1 | amber_regression | controllers | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-0.2.3-run-1 | amber_regression | jobs | 1 | 1/1 (100.0%) | 0/1 (0.0%) | 2/4 (50.0%) |
| round3b-0.2.3-run-1 | amber_regression | routing | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-0.2.3-run-1 | amber_regression | schema | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-0.2.3-run-1 | amber_regression | websockets | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-0.2.3-run-1 | grant_heldout | amber_tenant_pipe | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 2/18 (11.1%) |
| round3b-0.2.3-run-1 | grant_heldout | apartment_migration | 6 | 3/6 (50.0%) | 0/6 (0.0%) | 3/13 (23.1%) |
| round3b-0.2.3-run-1 | grant_heldout | parity | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 5/19 (26.3%) |
| round3b-0.2.3-run-1 | grant_heldout | raw_sql | 6 | 2/6 (33.3%) | 1/6 (16.7%) | 8/21 (38.1%) |
| round3b-0.2.3-run-1 | grant_heldout | row_tenancy | 7 | 1/7 (14.3%) | 0/7 (0.0%) | 6/18 (33.3%) |
| round3b-0.2.3-run-1 | grant_heldout | schema_tenancy | 6 | 2/6 (33.3%) | 1/6 (16.7%) | 6/18 (33.3%) |
| round3b-0.2.3-run-2 | amber_regression | controllers | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-0.2.3-run-2 | amber_regression | jobs | 1 | 1/1 (100.0%) | 0/1 (0.0%) | 2/4 (50.0%) |
| round3b-0.2.3-run-2 | amber_regression | routing | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-0.2.3-run-2 | amber_regression | schema | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-0.2.3-run-2 | amber_regression | websockets | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-0.2.3-run-2 | grant_heldout | amber_tenant_pipe | 6 | 0/6 (0.0%) | 0/6 (0.0%) | 2/18 (11.1%) |
| round3b-0.2.3-run-2 | grant_heldout | apartment_migration | 6 | 3/6 (50.0%) | 0/6 (0.0%) | 3/13 (23.1%) |
| round3b-0.2.3-run-2 | grant_heldout | parity | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 5/19 (26.3%) |
| round3b-0.2.3-run-2 | grant_heldout | raw_sql | 6 | 2/6 (33.3%) | 1/6 (16.7%) | 8/21 (38.1%) |
| round3b-0.2.3-run-2 | grant_heldout | row_tenancy | 7 | 1/7 (14.3%) | 0/7 (0.0%) | 6/18 (33.3%) |
| round3b-0.2.3-run-2 | grant_heldout | schema_tenancy | 6 | 2/6 (33.3%) | 1/6 (16.7%) | 6/18 (33.3%) |
| round3b-0.2.4-run-1 | amber_regression | controllers | 1 | 1/1 (100.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-0.2.4-run-1 | amber_regression | jobs | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 3/4 (75.0%) |
| round3b-0.2.4-run-1 | amber_regression | routing | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 0/3 (0.0%) |
| round3b-0.2.4-run-1 | amber_regression | schema | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-0.2.4-run-1 | amber_regression | websockets | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-0.2.4-run-1 | grant_heldout | amber_tenant_pipe | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 2/18 (11.1%) |
| round3b-0.2.4-run-1 | grant_heldout | apartment_migration | 6 | 2/6 (33.3%) | 0/6 (0.0%) | 1/13 (7.7%) |
| round3b-0.2.4-run-1 | grant_heldout | parity | 6 | 3/6 (50.0%) | 0/6 (0.0%) | 2/19 (10.5%) |
| round3b-0.2.4-run-1 | grant_heldout | raw_sql | 6 | 3/6 (50.0%) | 0/6 (0.0%) | 4/21 (19.0%) |
| round3b-0.2.4-run-1 | grant_heldout | row_tenancy | 7 | 4/7 (57.1%) | 0/7 (0.0%) | 4/18 (22.2%) |
| round3b-0.2.4-run-1 | grant_heldout | schema_tenancy | 6 | 4/6 (66.7%) | 0/6 (0.0%) | 2/18 (11.1%) |
| round3b-0.2.4-run-2 | amber_regression | controllers | 1 | 1/1 (100.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-0.2.4-run-2 | amber_regression | jobs | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 3/4 (75.0%) |
| round3b-0.2.4-run-2 | amber_regression | routing | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 0/3 (0.0%) |
| round3b-0.2.4-run-2 | amber_regression | schema | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 2/3 (66.7%) |
| round3b-0.2.4-run-2 | amber_regression | websockets | 1 | 0/1 (0.0%) | 0/1 (0.0%) | 1/3 (33.3%) |
| round3b-0.2.4-run-2 | grant_heldout | amber_tenant_pipe | 6 | 1/6 (16.7%) | 0/6 (0.0%) | 2/18 (11.1%) |
| round3b-0.2.4-run-2 | grant_heldout | apartment_migration | 6 | 2/6 (33.3%) | 0/6 (0.0%) | 1/13 (7.7%) |
| round3b-0.2.4-run-2 | grant_heldout | parity | 6 | 3/6 (50.0%) | 0/6 (0.0%) | 2/19 (10.5%) |
| round3b-0.2.4-run-2 | grant_heldout | raw_sql | 6 | 3/6 (50.0%) | 0/6 (0.0%) | 4/21 (19.0%) |
| round3b-0.2.4-run-2 | grant_heldout | row_tenancy | 7 | 4/7 (57.1%) | 0/7 (0.0%) | 4/18 (22.2%) |
| round3b-0.2.4-run-2 | grant_heldout | schema_tenancy | 6 | 4/6 (66.7%) | 0/6 (0.0%) | 2/18 (11.1%) |
run agreement round3b-0.2.3 (round3b-0.2.3-run-1 vs round3b-0.2.3-run-2): answers 42/42 (100.0%); compile+symbols 42/42 (100.0%)
run agreement round3b-0.2.4 (round3b-0.2.4-run-1 vs round3b-0.2.4-run-2): answers 42/42 (100.0%); compile+symbols 42/42 (100.0%)
