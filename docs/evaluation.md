# Evaluation methodology

The root Swift package provides the `decision-eval` command.
It calls the library directly and needs no Python.
It downloads datasets through the Hugging Face dataset viewer API,
samples them with a fixed-seed generator,
fits calibrations,
and writes JSON and CSV reports that record the hardware, model, datasets,
sampled row indices, prompt format, calibration, and cache settings.

| Command | What it measures |
| --- | --- |
| `sanity` | Nine hand-written cases with known answers. |
| `routing` | Support-ticket routing, with the fallback report. |
| `robustness` | Option order, paraphrase, negation, missing evidence, missing options, languages, classification manipulation, and injection detection. |
| `boolq`, `agnews` | Accuracy, ECE, NLL, Brier score, and accuracy by coverage on 200-item samples. |
| `calibrate` | A calibration fitted on one sample and reported on a held-out sample. |
| `latency` | Cold loading, and p50 and p95 batch latency for 1, 8, and 32 questions on short and long states, with peak memory. |

Run them with `mise run eval:<command>`.

Prefix caching is off by default.
Pass `--prefix-cache` only after you compare cached and uncached results
for the selected model and workload.
Each report records the selected cache setting.
See the [2026-09-21 prefix-cache evaluation](historical-results.md#prefix-cache-evaluation-2026-09-21)
for the measurements and the MLX causal-mask finding behind this default.

The routing and robustness labels were written for this package and have not been reviewed by a person.
Their provenance is recorded in each fixture file,
and reports repeat that status.
Review the labels before you publish results from them.

The evaluation code and fixtures came from AnyDecisionModel commit
`6ba547e5c63cd9a5e6d69215e1a29f5e7dcb9f8a`
and now use the AnyDecisionModel 0.6.0 API.
Run `mise run eval:sanity -- --help` for all options.

BoolQ uses the validation split of `google/boolq`.
AG News uses the test split of `fancyzhx/ag_news`.
The first dataset command downloads the full split, even for a small sample.
The dataset cache is `~/Library/Caches/AnyDecisionModel/datasets`.
Models are downloaded through the library's Hugging Face client and cached outside Git.
Setup resolves Swift dependencies only.

Reports go to `reports/` by default; use `--out` to select another directory.
Fixture, dataset, and latency commands write JSON and CSV.
Calibration writes a JSON report and a separate calibration JSON file.
Use `--revision` and `--model-revision` to record known source and model revisions.
Use separate fit and test samples when you assess calibration.
The historical metric definitions and measurements are in
[Historical results](historical-results.md).

For small checks, override the task defaults:

```bash
mise run eval:boolq -- --n 4
mise run eval:agnews -- --n 4
mise run eval:calibrate -- --fit 4 --test 4
mise run eval:latency -- --batches 1,2 --repetitions 1
```

These checks confirm command completion and report structure.
They do not establish model quality or reproduce the historical measurements.
The evaluator uses the local MLX backend.
It does not run live Jev benchmarks.
