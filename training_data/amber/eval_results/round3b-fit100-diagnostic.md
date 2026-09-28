# Round 3b 100-step Grant fit diagnostic

- Model: `mlx-community/gemma-3-4b-it-4bit@93724907d4ed1745d2fe50baadf3b0b01a65abf2`; weights SHA256 `94d3d701367d78584a9334ca00672b1c86e4aefa6a94167556c0485381e74af3`.
- Source filter: `amber-v2@0.2.0` (`683d65226b3f328f`).
- Run: SFT-only from pinned base, 100 iterations, rank 8, 16 layers, learning rate 0.0001, batch size 1, steps per report 1.
- Rows: 84 Grant loss-probe rows; 296 Amber SFT rows.
- Template: `model-chat-template`; `template_from` resolved the Gemma 3 template and selected the `GEMMA3` renderer. The first saved training row matches the preview text exactly: `true`.
- Completion-only loss (prompt masking): `false`.
- Train loss: 100 per-step reports; first 9.127889633178711, final 1.1641638278961182, minimum 0.47308385372161865, maximum 9.127889633178711.
- Grant loss: 4.863130569458008 before -> 0.7719460725784302 after.
- Validation loss at end: 0.991850733757019. Elapsed: 847705.0 ms.
- Token preview: [`round3b-fit100-token-preview.jsonl`](round3b-fit100-token-preview.jsonl); the `SpecialTokenAwareTrainingTokenizer` produced 287 IDs and decoded exactly to the training row with its added `<bos>` prefix.
- Upstream warning source: pinned `mlx-swift-lm` `Libraries/MLXLLM/LoraTrain.swift:50-66`. `LoRABatchIterator` warns when the current batch's longest row exceeds 2048, pads to the observed maximum, and shifts inputs/targets across the full sequence; it does not truncate. The prior full-corpus audit found 1/296 SFT rows over 2048, maximum 2148; 100 tokens would be lost only under hypothetical right truncation, while actual truncation was 0 rows.

## Per-iteration loss

| Iteration | Loss |
| ---: | ---: |
| 0 | 9.12788963 |
| 1 | 4.97898483 |
| 2 | 3.24067616 |
| 3 | 2.65327644 |
| 4 | 2.19919801 |
| 5 | 1.96623993 |
| 6 | 3.88750863 |
| 7 | 2.75046349 |
| 8 | 2.91397357 |
| 9 | 1.37693965 |
| 10 | 2.28366208 |
| 11 | 2.24343777 |
| 12 | 1.41545725 |
| 13 | 1.98802507 |
| 14 | 2.0318327 |
| 15 | 1.29379475 |
| 16 | 1.46300209 |
| 17 | 1.55589068 |
| 18 | 1.49310887 |
| 19 | 1.46136701 |
| 20 | 1.47931767 |
| 21 | 2.04700327 |
| 22 | 2.05925727 |
| 23 | 2.21563339 |
| 24 | 1.48499608 |
| 25 | 1.31206548 |
| 26 | 1.62765026 |
| 27 | 0.98757857 |
| 28 | 0.96942091 |
| 29 | 1.69036496 |
| 30 | 1.43551433 |
| 31 | 1.7424947 |
| 32 | 1.07508326 |
| 33 | 0.99744803 |
| 34 | 0.77613437 |
| 35 | 2.34604454 |
| 36 | 1.06030321 |
| 37 | 1.92804551 |
| 38 | 0.8000524 |
| 39 | 1.10978174 |
| 40 | 1.65717196 |
| 41 | 1.1872946 |
| 42 | 1.38887048 |
| 43 | 2.00609732 |
| 44 | 1.61799991 |
| 45 | 0.84683955 |
| 46 | 1.10713267 |
| 47 | 1.84547341 |
| 48 | 0.93311459 |
| 49 | 1.21692491 |
| 50 | 1.19420886 |
| 51 | 1.15601003 |
| 52 | 0.97342336 |
| 53 | 1.13537002 |
| 54 | 1.08912873 |
| 55 | 0.96941245 |
| 56 | 1.09269583 |
| 57 | 0.92860109 |
| 58 | 1.51390564 |
| 59 | 1.29572797 |
| 60 | 1.09442914 |
| 61 | 1.65915799 |
| 62 | 1.20644319 |
| 63 | 0.85887933 |
| 64 | 1.63505721 |
| 65 | 0.85670626 |
| 66 | 1.233881 |
| 67 | 1.40299368 |
| 68 | 1.12219751 |
| 69 | 0.84557891 |
| 70 | 0.85110849 |
| 71 | 1.20725203 |
| 72 | 0.99767226 |
| 73 | 1.03631067 |
| 74 | 0.93926257 |
| 75 | 1.02416456 |
| 76 | 1.34905422 |
| 77 | 0.93094897 |
| 78 | 1.30172145 |
| 79 | 0.59112555 |
| 80 | 0.74038804 |
| 81 | 0.68416589 |
| 82 | 0.9094969 |
| 83 | 1.2163142 |
| 84 | 0.47308385 |
| 85 | 1.29424381 |
| 86 | 0.95558995 |
| 87 | 0.96987778 |
| 88 | 1.48352063 |
| 89 | 0.88590211 |
| 90 | 0.71352535 |
| 91 | 1.05236793 |
| 92 | 0.85734487 |
| 93 | 0.92656326 |
| 94 | 0.79714906 |
| 95 | 1.15422308 |
| 96 | 1.66933477 |
| 97 | 1.40188432 |
| 98 | 1.38019443 |
| 99 | 1.16416383 |

Raw per-iteration reports and final summary: `round3b-fit100-loss.jsonl`.
