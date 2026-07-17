# AutoCompBench report

- Mode: `fixture`
- Configuration: `production`
- Manifest commit: `d7bda292486a477371175fbbc7578eff5d3c5c71`
- Cases: 25 (25 evaluated, 0 skipped)

| Metric | Value |
| --- | ---: |
| Correct show | 15 |
| Wrong show | 0 |
| Correct suppression | 10 |
| Incorrect suppression | 0 |
| Wrong-show rate | 0.00% |
| Precision when shown | 100.00% |
| Positive coverage | 100.00% |
| Duplicate-after-cursor rate | 0.00% |
| Stale-publication rate | 0.00% |
| Provider latency p50 / p95 | 8 / 25 ms |
| Provider calls | 20 |
| Prefill bytes / tokens | 653 / 167 |
| Scheduling cases / mismatches | 3 / 0 |
| Reuse cases / mismatches | 3 / 0 |
| Reuse promotion / rollback hits | 1 / 1 |
| Provider calls skipped by reuse | 2 |
| Speculation cases / mismatches | 3 / 0 |
| Speculation validated / diverged | 1 / 1 |
| Target / remaining debounce p50 | 140 / 50 ms |

## By tag

| Tag | Evaluated | Wrong show | Coverage |
| --- | ---: | ---: | ---: |
| `FIM` | 4 | 0 | 100.00% |
| `Unicode` | 2 | 0 | 100.00% |
| `append/end` | 6 | 0 | 100.00% |
| `apple-route` | 1 | 0 | 100.00% |
| `code/terminal-disabled` | 2 | 0 | 0.00% |
| `forbidden-patterns` | 1 | 0 | 100.00% |
| `host-timeout` | 1 | 0 | 100.00% |
| `insufficient-geometry` | 1 | 0 | 0.00% |
| `latency` | 9 | 0 | 100.00% |
| `local-route` | 2 | 0 | 100.00% |
| `mid-word` | 2 | 0 | 100.00% |
| `partial-overlap` | 1 | 0 | 100.00% |
| `post-acceptance` | 3 | 0 | 100.00% |
| `prompt/suffix-echo` | 1 | 0 | 100.00% |
| `rank-two` | 1 | 0 | 0.00% |
| `rapid-typing` | 1 | 0 | 100.00% |
| `remote-route` | 2 | 0 | 100.00% |
| `reuse` | 3 | 0 | 0.00% |
| `risky-chat` | 1 | 0 | 0.00% |
| `rollback` | 1 | 0 | 0.00% |
| `scheduling` | 3 | 0 | 100.00% |
| `selection` | 1 | 0 | 0.00% |
| `speculation` | 3 | 0 | 100.00% |
| `stale` | 3 | 0 | 100.00% |
| `suffix-duplicate` | 4 | 0 | 100.00% |
| `whitespace` | 1 | 0 | 100.00% |

## By backend

| Backend | Evaluated | Wrong show | Coverage |
| --- | ---: | ---: | ---: |
| `fixture` | 25 | 0 | 100.00% |

## By model row

| Model row | Evaluated | Wrong show | Coverage |
| --- | ---: | ---: | ---: |
| `fixture-v1` | 25 | 0 | 100.00% |
