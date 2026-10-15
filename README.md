# AnyDecisionModel Examples

Examples and evaluation tools for
[AnyDecisionModel](https://github.com/mattt/AnyDecisionModel),
a Swift package for typed decisions from language models.

This repository contains four things:

- [Ticket routing](#ticket-routing), a command-line example that routes
  support tickets with a typed choice, a probability, and a score.
- [Chess](#chess), a macOS app in `Examples/Chess` that plays chess with a
  local model and shows the probability of each move it considers.
- [Emoji Magnet](#emoji-magnet), a macOS app in `Examples/EmojiMagnet` that
  pulls matching emoji out of a pile as you type a description.
- [Evaluations](#evaluations), a `decision-eval` command that measures
  accuracy, calibration, robustness, and latency on public datasets and
  local fixtures.

The root Swift package builds `TicketRouting`, `decision-eval`,
`DecisionEvaluation`, and the evaluation tests.
Each app has its own Xcode project and test target.

## Requirements

- Use an Apple silicon Mac with macOS 26 or later.
- Install Xcode 27 with Swift 6.4 or later and select it with `xcode-select`.
  The package manifest requires Swift 6.2; these workflows use the Swift Build
  engine provided by Xcode's Swift 6.4 toolchain to compile MLX Metal shaders.
- Install the Metal toolchain with `xcodebuild -downloadComponent MetalToolchain`.
- Install [mise](https://mise.jdx.dev/), for example with `brew install mise`.
- Allow network access for Swift dependencies and the first model or dataset use.
- For the optional Jev backend, set `TYPESAFE_AI_API_KEY`.
  Do not put keys in Git.
  The default examples use MLX and need no Jev credential.

The package pins AnyDecisionModel 0.5.0 with its `MLX` trait.
`Package.resolved` records the resolved revisions.
No sibling library checkout is required.
The examples pass the model identifier explicitly and default to
`mlx-community/Qwen3-4B-Instruct-2507-4bit`, a 2.3 GB download on first use.
The hidden MLX task in `mise.toml` uses `xcrun swift`
so that a different `swift` on `PATH`
does not select a toolchain without the required build engine.

## Development

After cloning, run `mise trust` once to trust the checked-out task configuration.
Then run `mise run setup` to resolve dependencies.
Setup is safe to repeat and does not download models or datasets.

| Task | Description |
| --- | --- |
| `mise run setup` | Resolve package, Chess, and Emoji Magnet dependencies. |
| `mise run lint` | Check formatting of the root package. |
| `mise run build` | Build both executables in release mode. |
| `mise run test` | Run the evaluation, Chess, and Emoji Magnet tests. |
| `mise run example` | Run ticket routing with local MLX. |
| `mise run build:chess` | Build the macOS Chess app in `.build/xcode-chess`. |
| `mise run test:chess` | Run the offline chess rule and decision tests. |
| `mise run example:chess` | Build and open the macOS Chess app. |
| `mise run build:emoji-magnet` | Build the Emoji Magnet app in `.build/xcode-emoji-magnet`. |
| `mise run test:emoji-magnet` | Run the offline Emoji Magnet tests. |
| `mise run example:emoji-magnet` | Build and open the macOS Emoji Magnet app; pass `--jev` to use Jev. |
| `mise run eval:sanity` | Run the nine sanity cases. |
| `mise run eval:routing` | Run routing fixtures and the fallback report. |
| `mise run eval:robustness` | Run robustness probes. |
| `mise run eval:boolq` | Evaluate a BoolQ sample. |
| `mise run eval:agnews` | Evaluate an AG News sample. |
| `mise run eval:calibrate` | Fit calibration and assess held-out samples. |
| `mise run eval:latency` | Measure model loading and batch latency. |

The commands also work in non-interactive terminal shells.
No local server or allocated port is needed.
Generated reports, datasets, model weights, and build files are excluded from Git.

## Ticket routing

The example routes four support tickets with a typed choice.
Tickets below the routing confidence threshold go to a person.
It never switches to a cloud model on its own.
Use `mise run example -- --threshold 0.7` to change the threshold,
or `mise run example -- --jev` to select Jev explicitly.
The Jev backend reads its API key from `TYPESAFE_AI_API_KEY`.
The whole example, including its typed `Department` choice, is in
[`Sources/TicketRouting/main.swift`](Sources/TicketRouting/main.swift).
Its output for the first ticket looks like this:

```text
Ticket: I was charged twice this month and nobody has answered my emails in a week. Fix this NOW.
  team:    billing [billing 1.00, technical 0.00, sales 0.00], confidence 1.00
  route:   billing
  urgent:  1.000
  anger:   1.68 of 0 to 2 (Very angry)
```

## Chess

![The Chess app after the model played Bb3, with the move list and the position assessment in the inspector](docs/images/chess.png)

The Chess app supports a human playing White, a human playing Black, and model
self-play.
Human White is the default.
Self-play has Start, Pause, and Step controls.
New Game clears the current in-memory game, and the app does not save games after
the current session.

The window toolbar has New Game, the mode picker, the self-play controls,
Flip Board, and the inspector button.
The menu bar has the same commands:

| Command | Menu | Shortcut |
| --- | --- | --- |
| New Game | File | ⌘N |
| Mode, Start or Pause Self-Play, Step Self-Play, Retry Model Move | Game | ⌘R starts or pauses; ⌘→ steps |
| Flip Board | View | ⇧⌘F |
| Show or Hide Inspector | View | ⌥⌘I |

The board shows the human player's color at the bottom.
Self-play shows White at the bottom.
Flip Board changes only the orientation, and a mode change resets it.
Click a piece and then a destination to move.
With the keyboard, Tab moves focus to the board,
the arrow keys move a cursor in the displayed direction,
Return or Space selects the square under the cursor,
and Escape clears the selection.
The selected piece, legal destinations, captures, the last move, and a king in check
each have a different shape as well as a different color.
VoiceOver reads each square's coordinate, piece, and state.

The inspector shows the moves in standard algebraic notation,
with White and Black in numbered rows.
It follows new moves unless you scroll back.
It also shows the last model assessment as five probability bars,
with the selected move and the elapsed time.
The assessment describes the position before that move.
Details contains the FEN and the expected level from 0 to 4.
Move probabilities stay in their original question groups.

Debug builds accept `-ChessFixture` with `thinking`, `failure`, `grouped`,
`promotion`, `checkmate`, or `self-play`.
These fixtures use a deterministic model and do not download weights.
For example:

```sh
open ".build/xcode-chess/Build/Products/Debug/AnyDecisionModel Chess.app" \
    --args -ChessFixture grouped
```

The app uses `mlx-community/Qwen3-4B-Instruct-2507-4bit` on the local Mac.
The first model move can download model weights and can take longer than later moves.
The app sandbox permits outbound network access for this download.

The model calls live in
[`Examples/Chess/Chess/ChessDecisionService.swift`](Examples/Chess/Chess/ChessDecisionService.swift).
Each model turn creates one decision session for the current position.
The state contains an ASCII board, FEN, the side to move, check status, and the
coordinate move history.
The model first scores the position on five levels from a clear Black advantage to
a clear White advantage.
It then selects a legal UCI move.
If a position has more than 26 legal moves, the app sorts the identifiers, asks
about groups of no more than 26, and repeats with the group winners.
The interface keeps each group's probability distribution separate because
probabilities from different questions are not comparable as one distribution.

The Chess target uses synchronous value-based rules for all human and model moves.
It implements king safety, castling, en passant, and queen, rook, bishop, and knight
promotions.
A game ends on checkmate, stalemate, threefold repetition, 100 halfmoves without a
pawn move or capture, or insufficient material.
The insufficient-material cases are bare kings, one bishop or knight against a
king, and bishop-only positions when every bishop is on the same square color.

The SwiftUI board and asset catalog came from the Chess repository at commit
`0c85c3c82182cb0cf69e5d3c15f919ddeb752464`.
The rule engine and model controller were replaced for this example.

## Emoji Magnet

![Emoji Magnet with the phrase "things you wear" and twelve clothing items above the pile](docs/images/emoji-magnet.png)

Emoji Magnet shows a large text field above a pile of 343 emoji.
Type a phrase, such as "things you wear",
and the items that match rise to a row below the field.
Refine the phrase to "things you wear in winter",
and the items that no longer match fall back into the pile.
Drag an item to move it, or toss it by releasing it while it moves.
Escape and the clear button clear the phrase and release every item.
With Reduce Motion on, the items move directly between a tidy pile and the rows,
without falling or tossing.

The catalog includes 124 animal emoji, plus clothing, food, plants, transport,
tools, household objects, electronics, office supplies, musical instruments,
and sports equipment and toys.
The animal list covers animal emoji through Emoji 17.0,
checked against [Unicode's emoji data](https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt).
Animal heads and mythical creatures are included;
standalone animal body parts, tracks, and microbes are excluded from that list.
Expression faces, people, abstract symbols, and flags are omitted from the catalog.
The newest emoji depend on the installed macOS emoji font.
Sprites shrink to fit the catalog in smaller windows.
Each item has a stable identifier, an emoji, and a plain-language description.
The app uses Jev when `TYPESAFE_AI_API_KEY` is present in its environment.
Otherwise, it uses `mlx-community/Qwen3-4B-Instruct-2507-4bit` on the local Mac.
Run `mise run example:emoji-magnet --jev` to pass the API key from the task
environment to a new app instance.
The app prepares the selected model when the window opens.
The first MLX launch can download model weights and take several minutes;
typing and the physics stay active while the model loads.
The app sandbox permits outbound network access for this download.

The model calls live in
[`Examples/EmojiMagnet/EmojiMagnet/EmojiMatchService.swift`](Examples/EmojiMagnet/EmojiMagnet/EmojiMatchService.swift).
When typing pauses for 250 milliseconds,
the app creates one decision session.
Its state holds the phrase and the rule that an item must satisfy the whole phrase,
including qualifiers and negation.
The app asks one yes-or-no question for each item,
with the item's description and the phrase in the same statement:
`Statement: a dog fits the description "pet". Is this statement true?`
Jev receives all questions in one request.
MLX receives questions in groups of 16,
with the items that matched the previous phrase first.
MLX evaluates the shared state once with prefix caching,
then evaluates each group's 16 prompts together in one forward pass.
With the original 48-item catalog on an M4 Max, a group took about 0.4 seconds
and the whole catalog about 1.3 seconds once the model was loaded.
The expanded 343-item catalog requires 22 MLX groups per phrase.
Each group's results apply as soon as they arrive,
and a probability above 0.5 attracts the item.
Items keep their previous state until their new result arrives.
Every phrase reevaluates the whole catalog,
so a broader phrase can bring back items that a narrower phrase released.
A new phrase cancels the running evaluation,
and only the newest waiting phrase runs next.
The app has no keyword rules, history, or saved state.

Debug builds accept `-EmojiMagnetFixture` with `matches`, `loading`, or `failure`.
These fixtures use a deterministic model and do not download weights.
The `matches` fixture answers "things you wear",
"things you wear in winter", "animals", and "anything";
every other phrase matches nothing.
For example:

```sh
open ".build/xcode-emoji-magnet/Build/Products/Debug/AnyDecisionModel Emoji Magnet.app" \
    --args -EmojiMagnetFixture matches
```

`EmojiMagnetDebugAutomation.swift` describes launch options
that type phrases, toss items, resize the window, and save snapshots.

## Evaluations

See [Evaluation methodology](docs/evaluation.md) for commands, datasets, reports,
fixture provenance, and small validation runs.
[Historical results](docs/historical-results.md) preserves the library README's
measurements from 2026-09-19, with their conditions and limitations.
The local MLX examples and evaluation commands keep prefix caching off.
The evaluator provides `--prefix-cache` for validated comparisons.
Routing and robustness fixture labels have not been reviewed by a person.

## License

This repository is available under the Apache License, Version 2.0.
See [LICENSE](LICENSE) for the full text.
