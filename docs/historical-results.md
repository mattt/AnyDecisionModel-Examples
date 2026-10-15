# Historical results

These results were recorded in the library README before this repository was created.
They are historical measurements, not results from validation of this repository.
The original dates, conditions, and limitations follow.


These results are for `mlx-community/Qwen3-4B-Instruct-2507-4bit`
with raw probabilities and the prefix cache on.
Hardware: Apple M4 Max, 36 GB, macOS 27.0. Date: 2026-09-19.
One run each; no confidence intervals.

The tables report three measures of probability quality, and lower is better for each.
[Expected calibration error](https://en.wikipedia.org/wiki/Calibration_(statistics)#In_classification)
(ECE) sorts predictions into 10 equal-width bins
by the probability of the most probable answer.
It then takes the average gap between that probability and the accuracy in each bin,
weighted by bin size.
An ECE of 0.12 means that the stated probabilities are off by 12 percentage points on average.
[Negative log-likelihood](https://en.wikipedia.org/wiki/Cross-entropy#Cross-entropy_loss_function_and_logistic_regression)
(NLL), also called log loss, is the mean of $-\log p$,
where $p$ is the probability that the model gave to the correct answer.
NLL has no upper limit, so a few confident wrong answers raise it sharply.
The [Brier score](https://en.wikipedia.org/wiki/Brier_score) is the mean squared difference
between the probabilities and the correct answer:
$(p_{yes} - y)^2$ for binary questions and $\sum_k (p_k - y_k)^2$ for choices.

| Task | Accuracy | ECE | NLL | Brier | p50 per decision |
| --- | --- | --- | --- | --- | --- |
| BoolQ, 200 items, seed 0 | 0.880 | 0.120 | 1.428 | 0.116 | 169 ms |
| AG News, 200 items, seed 0 | 0.895 | 0.102 | 1.590 | 0.200 | 136 ms |
| AG News with rotation debiasing | 0.900 | 0.096 | 1.355 | 0.191 | 297 ms |

Calibration fitted jointly on 200 BoolQ and 200 AG News items (seed 1)
gave a temperature of 6.5 and a binary bias of 1.0.
On 200 held-out items of each task:

| Task | Setting | Accuracy | ECE | NLL | Brier |
| --- | --- | --- | --- | --- | --- |
| BoolQ | Raw | 0.840 | 0.153 | 1.773 | 0.148 |
| BoolQ | Calibrated | 0.850 | 0.056 | 0.336 | 0.107 |
| AG News | Raw | 0.895 | 0.098 | 1.282 | 0.197 |
| AG News | Calibrated | 0.895 | 0.059 | 0.364 | 0.169 |

The evaluation also ran nine sanity cases, such as a coin flip and a frustration score.
All seven cases that have a pass condition passed.
The coin flip gave 0.592 for heads,
and the frustration score was 1.68 (0.32 on "Frustrated", 0.68 on "Very angry").

Latency, with a new session for each batch (10 repetitions):

| State | Prompt tokens per question | Batch | p50 per batch | p50 per question |
| --- | --- | --- | --- | --- |
| Short | 85 to 99 | 1 | 103 ms | 103 ms |
| Short | 85 to 99 | 8 | 418 ms | 52 ms |
| Short | 85 to 99 | 32 | 1,652 ms | 52 ms |
| Long | 1,189 to 1,203 | 1 | 1,014 ms | 1,014 ms |
| Long | 1,189 to 1,203 | 8 | 1,462 ms | 183 ms |
| Long | 1,189 to 1,203 | 32 | 2,880 ms | 90 ms |

Loading the weights took 0.55 s after the files were downloaded and in the OS file cache.
Peak process memory footprint during the latency run was 4.4 GiB.

Robustness probes (33 cases, with labels that a person has not reviewed):
option-order permutations and negation pairs were consistent,
and paraphrases agreed within 0.042.
Two of three classification-manipulation attempts changed the answer,
for example routing a billing ticket to sales when the ticket told the classifier to.
Injection detection flagged a benign request ("Please ship the order to my office address") at 0.963.
Two of three missing-evidence questions stayed between 0.2 and 0.8.
A vague ticket ("Hi, I have a question.") was routed to technical with confidence 0.98,
which shows that confidence is not correctness.

## Prefix-cache evaluation, 2026-09-21

This follow-up compared cached and uncached evaluation with
`mlx-community/Qwen3-4B-Instruct-2507-4bit` at model revision
`50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b`.
It used an Apple M4 Max with 36 GiB of memory,
mlx-swift 0.31.4, and mlx-swift-lm 3.31.4.
No calibration was applied.

The default text prompt produced the same most-probable answer in all 809 cases.
Every cached run reused the state prefix.

| Task | Cases | Largest probability difference | Answer changes |
| --- | ---: | ---: | ---: |
| Sanity | 9 | 0 | 0 |
| BoolQ, seed 0 | 200 | 0.00000474 | 0 |
| BoolQ, seed 1 | 400 | 0.00000474 | 0 |
| AG News | 200 | 0.0000569 | 0 |

This sample found no answer changes with the default prompt.
It does not show that prefix caching is safe for all prompts, models, or split points.

An internal JSON prompt experiment exposed a large error at a 66-token split.
The uncached score assigned probabilities 0.0032 and 0.9968 to the two leading levels.
The cached score reversed them to 0.9526 and 0.0474.
The prompt tokens were the same in both runs.

An attention-only probe reproduced the cause without model weights or quantization.
For 62 queries and 128 keys, the first query may attend only to positions 0 through 66,
whose mean position is 33.
MLX's symbolic causal mask returned 39.5,
while an explicit lower-right causal mask returned 33.
The symbolic result matches the mean through position 79,
which means that the operation included future keys.
The [MLX API](https://ml-explore.github.io/mlx/build/html/python/_autosummary/mlx.core.fast.scaled_dot_product_attention.html)
specifies lower-right alignment.
The observed result is consistent with the
[Metal kernel condition](https://github.com/ml-explore/mlx/blob/ce45c52505c8158ea48d2a54e8caae05efd86bfe/mlx/backend/metal/kernels/steel/attn/kernels/steel_attention.h#L301)
that selects blocks for elementwise masking.

An explicit mask restored the affected model probabilities at the normal split.
Other small differences remained at arbitrary split points,
so this intervention did not establish general equivalence between split and one-pass evaluation.
AnyDecisionModel therefore
[disabled prefix caching by default](https://github.com/mattt/AnyDecisionModel/pull/7).
The evaluator follows that default and offers `--prefix-cache` as an explicit opt-in.

## Limitations

- Wire compatibility with Jev is tested against fixtures, not against the live service.
  Live Jev benchmarking and publication are deferred
  until the applicable account terms are clarified
  ([TypeSafe agreement](https://typesafe.ai/legal/mca)).
  Wire compatibility says nothing about model quality.
- Calibration was fitted on two tasks. Whether it transfers to other tasks is untested.
- Local confidence measures concentration. The model can be confident and wrong.
- Classification manipulation succeeded in two of three probes.
  Do not rely on typed output alone to resist injected instructions.
- Choices are limited to 26 options and scores to 10 levels.
- Inference is not optimized beyond prefix caching.
  Further optimization waits until profiling justifies it.

