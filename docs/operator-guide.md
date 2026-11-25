# The Gomoku Lab — Operator's Guide

How to run the AlphaZero loop for Gomoku: generate self-play corpora,
train candidates, gate them in the arena, promote, repeat. This guide
covers the binaries (`selfplaygen`, `selfplayexport`, `arenagen`,
`nettrain`), the production scripts (`mass-corpus.sh`,
`corpus-export.sh`), and the GUI as the laboratory's eyes.

The two source repositories:

- **rust-ml** (`gomoku/` workspace) — engine, MCTS, self-play, training.
  Owns all data production and the training authority.
- **gomoku-gui** — the native macOS lab: play against the engines,
  browse corpora, watch what the model sees.

Throughout, `$GOMOKU` means the `gomoku/` directory of the rust-ml
checkout, and *lab directory* means the working area holding
`data/corpora/`, `data/check-points/`, and `data/openings/` — by
default rust-ml's own `data/`.

---

## 1. The loop

```
        ┌──────────────────────────────────────────────┐
        │                                              │
        ▼                                              │
  selfplaygen ──► corpus chunks ──► selfplayexport ──► nettrain
  (search is                                     (policy+value
   the teacher)                                   distilled)
                                                       │
                                                       ▼
                                                  arenagen ──► promoted?
                                                  (Wilson 95%,      │ yes
                                                   equal sims)      ▼
                                                       │      new champion:
                                                       │      self-play with
                                                       └──────  better labels
```

The generator is the teacher: corpus labels are what *search* concluded
(visit distributions) and what *happened* (game outcomes), not what any
player's raw prior believed. Training distills that into a cheap prior;
the arena decides promotion strictly on equal-sims strength.

---

## 2. Data layout

```
data/
  openings/
    gomocup-2024-freestyle15.txt   # 12 complete Swap2 openings (seed → opening)
  corpora/
    <name>/                        # ONE selfplaygen run = one corpus
      manifest.json                # written LAST — presence means "sealed"
      shard-000.bin ...            # length-prefixed bincode records
    mass-2026-11-20/               # a chunked production run: 350 corpora
      800v800-w00-c00/ ...
      progress.log  logs/
    mass-2026-11-20-samples/       # an export: training-ready samples
  check-points/
    <run-name>/                    # ONE nettrain run
      model.mpk                    # the weights (full precision)
      run.json                     # the journal: config, data provenance
      metrics.jsonl                # per-step losses
```

Vocabulary:

- **Corpus** — recorded games with per-ply search data (visits, priors,
  root values). Browsable, exportable.
- **Sealed chunk** — a corpus directory whose `manifest.json` exists.
  Only sealed chunks are ever read, exported, or skipped.
- **Run directory** — a nettrain output. The GUI's *checkpoint root* is
  the folder that **contains** run directories.

---

## 3. The binaries

All are built from `$GOMOKU` with `cargo build --release -p <crate>` and
live in `target/release/`. **Flag syntax is always `--flag value`**
(never `--flag=value`).

### selfplaygen — corpus generation

```bash
./target/release/selfplaygen \
  --out <DIR> --openings <PATH> \
  --black-sims 1600 --white-sims 1600 \
  --games 25 --seed-base 3000000 \
  [--black-net <RUN_DIR>] [--white-net <RUN_DIR>] \
  [--exploration-plies 10] [--shard-capacity 1000]
```

- Seats default to the baseline evaluator; `--black-net`/`--white-net`
  seat trained nets (Flex CPU).
- **Safety:** refuses a non-empty `--out` unless `--overwrite`. The
  manifest is written last, so a killed run leaves a directory that is
  visibly *not* a corpus.
- One process plays seeds `seed-base .. seed-base+games-1`, each seed
  drawing its opening from the tournament list. Each opening is a
  *complete* Swap2 description — the 3-stone offer plus the recorded
  answer (take a color, or add two stones) from real Gomocup play —
  executed through the engine's Swap2 typestate; the players start
  thinking at ply 3 or 5. Parallel generation =
  several processes over disjoint seed ranges (the scripts do this).
- Exploration: temperature 1.0 + Dirichlet noise for the first
  `--exploration-plies` plies (default 10), then deterministic.

### selfplayexport — corpus → training samples

```bash
./target/release/selfplayexport \
  --corpus <DIR>[:WEIGHT] [--corpus <DIR>[:WEIGHT] ...] \
  --out <DIR> [--mix-seed 42]
```

Mixes corpora (weights scale each source's contribution; default 1.0),
rebuilds every training board from the move list, and writes
`policy`/`value` targets: π = normalized visits (one-hot on the proved
move when TSS ended the search), z = game outcome from the
side-to-move's perspective. Deterministic given the same inputs.

### nettrain — the training authority

```bash
cargo run --release -p net --features gpu --bin nettrain -- \
  --data <SAMPLES_DIR> --out <RUN_DIR> \
  --config default --device metal --steps 20000 --batch-size 256
```

- Configs: `tiny` (8ch×1), `mid` (32ch×4), `default` (128ch×10,
  3.17M params). `default` is justified from ~100k samples up.
- Without `--features gpu`, training runs on CPU (slow). `--device
  metal` uses the Apple GPU.
- Watch progress: `tail -f <RUN_DIR>/metrics.jsonl`.

### arenagen — the promotion gate

```bash
./target/release/arenagen \
  --net <RUN_DIR> --openings <PATH> \
  --games 40 --sims 800 \
  [--seed-base 0] [--incumbent-net <RUN_DIR>] [--record <DIR>]
```

- Candidate vs an incumbent: the **baseline** by default, or the
  reigning champion net with `--incumbent-net` (the round-2+ gate).
  Equal sims, no exploration, resignation on. Games come in
  color-swapped pairs sharing a seed — same opening, both colors.
- Verdict: Wilson 95% interval on the candidate's score (win 1,
  draw ½). **Promoted iff the lower bound clears 0.5.** Promotions
  claimed from a few lucky games are exactly what this prevents.
- `--record <DIR>` writes the arena games as a browsable corpus. The
  candidate's color flips per game, so the pairing lives in each
  record's own evaluator string; the manifest's seat block stays empty
  rather than averaging into a lie.
- Prefer the wrapper `scripts/arena.sh`, which supplies the openings
  path and a timestamped record directory automatically.

---

## 4. The production scripts

Both live in `$GOMOKU/scripts/` and resolve all paths from their own
location — run them from anywhere.

### mass-corpus.sh — chunked, resumable, start/stop-safe

```bash
scripts/mass-corpus.sh                                   # balanced
PROFILE=deep scripts/mass-corpus.sh                      # deep
NET=<RUN_DIR> PROFILE=net nohup scripts/mass-corpus.sh & # champion self-play
```

**The contract:** workers generate small chunks; a chunk is a sealed
corpus the moment its manifest lands. Kill the run any time (reboot,
training, vacation) — you lose at most the in-flight chunks. Rerun the
*identical command* to resume: sealed chunks are skipped, interrupted
chunks (no manifest) are wiped and regenerated, and `selfplaygen`
itself refuses to overwrite anything complete. Overwriting is
structurally impossible.

Profiles:

| Profile   | Sims mix | Purpose |
|-----------|----------|---------|
| `balanced` | 800/800 · 400/400 · 1200/800 · 800/1200 · 1600/1600 | Baseline volume + strength grading (~20h for 17.5k games at 12 workers) |
| `deep`     | 3000/3000 · 3000/4000 · 4000/4000 | Strong-search labels (the distillation experiment) |
| `net`      | 70% asymmetric 400/800 + 800/400, 30% symmetric 400/400 + 800/800 | Champion self-play production, night after night (~60–100 games/h at 8–10 workers, measured; defaults to 14) |

- `net` requires `NET=<RUN_DIR>`; output defaults to
  `selfplay-v1-<run-name>` — generation-pinned, so a new champion
  automatically writes a new directory. Run it every night with the
  same command: the corpus only grows (sealed chunks are skipped,
  interrupted ones redone).
- Knobs (env): `WORKERS` (12; 14 for net), `CYCLES` (4 / 8 / 999),
  `CHUNK_GAMES` (25; 10 for net), `OUT`, `OPENINGS`, `EXPORT_OUT`.
- Seed ranges are disjoint per profile (offsets 0 / 100M / 200M).
- Progress: `tail -f $OUT/progress.log`; per-worker detail in
  `$OUT/logs/`.
- Bounded profiles end with an automatic mixed export to
  `$OUT-samples`. The open-ended `net` profile never ends — use
  `corpus-export.sh` instead.

### corpus-export.sh — snapshot while production runs

```bash
scripts/corpus-export.sh <corpus-root> [samples-dir]
# -> <corpus-root>-samples-2026-11-22-0815
```

Mixes every *sealed* chunk under the root into a timestamped samples
directory. Safe mid-production (in-flight chunks are ignored) and
never overwrites — each snapshot is a new directory. Train on
snapshots as often as you like; later snapshots simply subsume earlier
ones.

---

## 5. The GUI as the laboratory

Launch: `cargo run --release -p gui` in gomoku-gui. Settings persist
in `~/.gomoku/config.toml`.

### Seating a trained net

Two-level selection, per seat, in the **Players** section:

1. **Settings → Checkpoint root** — the folder that *contains* run
   directories (e.g. `data/check-points`). Set once. Picking a run
   directory itself finds nothing (its children are scanned).
2. **Engine** — `Baseline AI` or `Trained net`.
3. **Checkpoint** — appears when Engine = Trained net; lists every
   valid run in the root (`name  128ch×10blocks  seed=0`).

A run directory is valid when it holds `model.mpk` + `run.json`.

### Reading the policy overlay

On any finished-ply position (Toggle: policy), each legal move shows
the **PUCT value view**: a small ✓/±/= badge (winning/drawish/losing
after full search), the visit share as a ring, and the headline number
is the **value target z** — what training actually learns. `tss`
badges mark threat-searched moves; `proven` marks a forced-win proof.
Outside recorded plies the overlay falls back to a live baseline
search.

### The corpus browser (Lab Explorer)

The Explorer section opens `.gomoku` games **and corpora** (any
directory with a manifest — including arena corpora recorded with
`--record`). For a corpus:

- **Manifest card**: game count, plies, sims, evaluators, shard stats.
- **Game list**: all recorded games; click to load one onto the board.
- **Move list**: step through plies; the overlay shows exactly what
  the learning model sees (π rings, z headline). The **Seats:** line
  names the record's per-game evaluator pairing — essential for arena
  corpora, where the candidate's color flips every game.

### Playing

Hotseat vs AI, AI vs AI (Watch), tournament mode. Strength knobs per
seat: engine, checkpoint, simulations, temperature. The GUI infers
nothing — what you select is what plays.

---

## 6. Recipes

### A. Bootstrap (done once, kept for reference)

```bash
nohup scripts/mass-corpus.sh &        # balanced, ~20h, 12 workers
# -> ../data/corpora/mass-2026-11-20-samples (auto-export)
```

### B. Train a candidate

```bash
cargo run --release -p net --features gpu --bin nettrain -- \
  --data ../data/corpora/<samples> \
  --out ../data/check-points/<candidate-name> \
  --config default --device metal --steps 20000 --batch-size 256
```

### C. Arena gate

```bash
scripts/arena.sh ../data/check-points/<candidate-name>
# round 2 and beyond: gate against the reigning champion
scripts/arena.sh ../data/check-points/<candidate-name> \
  --incumbent-net ../data/check-points/<champion>
```

40 games at 800 sims by default; the games are recorded to a
timestamped `arena-<candidate>-vs-<incumbent>-<stamp>` corpus.
Promoted iff the Wilson lower bound > 0.5. Browse the recorded arena
corpus in the GUI to *see* where the candidate won and lost.

### D. Champion self-play production (the long run)

```bash
NET=../data/check-points/<champion> PROFILE=net nohup scripts/mass-corpus.sh &
# days/weeks later, any time:
scripts/corpus-export.sh ../data/corpora/selfplay-v1-<champion>
```

Stop whenever; restart with the same command. Snapshot weekly; train
round N+1 on a weighted mix:

```bash
./target/release/selfplayexport \
  --corpus ../data/corpora/selfplay-v1-<champion>-samples-<stamp>:3 \
  --corpus ../data/corpora/mass-2026-11-20-samples:1 \
  --out ../data/corpora/round2-samples
```

(Weight the fresh self-play higher — its labels come from the stronger
teacher — but keep baseline volume for coverage.)

### E. Inspect anything

GUI → Explorer → open the corpus / arena record / game. The overlay
always answers "what would training learn from this position?"

---

## 7. Provenance and reproducibility

- Every corpus names its seeds; seed → opening is deterministic.
  Regenerating a chunk with the same command yields the same games.
- Every record carries its own evaluator string
  (`black=net:<run>@<version> white=baseline@<version>`); the manifest
  carries the corpus-level pairing and, for mixed corpora, per-source
  weights and games.
- Exports are deterministic given the same inputs and `--mix-seed`.
- Shards are length-prefixed bincode: append-only, never edited in
  place. Provenance lives in JSON manifests, not in the binary layout.

## 8. The safety rules (summary)

1. Nothing overwrites: `selfplaygen` refuses non-empty outputs;
   snapshots are timestamped; a new champion writes a new directory.
2. Manifest-last: a directory with `manifest.json` is sealed; without
   it, it's garbage-in-progress and may be wiped.
3. Disjoint seed ranges per profile and per worker.
4. The arena promotes on statistics (Wilson lower bound), never on
   impressions.
5. The GUI observes and launches; only `nettrain` writes models.
