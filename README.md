# gmklabs — the Gomoku laboratory installer

## Abstract

gmklabs builds and installs the Gomoku project's tools into a single
coherent environment. The project spans two source repositories —
[rust-ml](https://github.com/Project-Ellie/rust-ml), which owns the
rules engine, search, and training pipeline, and
[gomoku-gui](https://github.com/Project-Ellie/gomoku-gui), the native
macOS application that is becoming the project's training laboratory.
gmklabs fetches both at pinned revisions, compiles their non-demo
binaries, and installs them — together with convenience scripts and a
user-level configuration — into a prefix on `PATH` (default
`~/.local`). The source repositories stay clean; all fetching and
building happens in this repository's `build/` area. Run `make
install`, then work in any working directory of your choice.

## Glossary

- **Lab** — the live environment where tools run: datasets,
  checkpoints, training runs, and the GUI's views over them. The lab
  is a *working directory*, not a repository.
- **Prefix** — the installation root (default `~/.local`); binaries
  and scripts land in `<prefix>/bin`.
- **Pin** — a git revision naming exactly one version of a source
  repository.
- **Training authority** — rust-ml's `nettrain`, the only program
  that writes model records and run journals. The GUI observes and
  launches it; it never trains on its own.
- **Demo binary** — an executable that exists to demonstrate a crate
  (e.g. `historydemo`, `patterndemo`). Demo binaries are not
  installed.

## The four locations

| Location | Role | Chosen by |
|---|---|---|
| Source repositories (rust-ml, gomoku-gui) | Where tools are *developed*. Clean source; no data, no run artifacts. | fixed |
| Prefix (`~/.local` by default) | Where installed artifacts live: binaries, scripts, the GUI. On `PATH`. | user, at install time |
| `~/.gomoku/` | User-level configuration (`config.json`): bin directory, default lab. | convention |
| Working directory | Where tools *run*: datasets, checkpoints, run journals. | user, per session |

## Version consistency: one pin chain

Two revisions must agree, or the GUI and the command-line tools could
disagree about record formats. gmklabs stores exactly one pin:
gomoku-gui's revision in [gmklabs.toml](gmklabs.toml). rust-ml's
revision is *not* stored here — gomoku-gui already pins rust-ml by
git revision in its own `Cargo.toml`, and `make install` reads the
revision from the fetched checkout. The dependency direction stays
one-way: gmklabs → gomoku-gui → rust-ml. Neither source repository
needs any change.

## Usage

```sh
make install    # fetch, build, install (long: cold release builds)
make doctor     # verify binaries, PATH, and config
```

Overridable variables: `PREFIX` (default `~/.local`), `GOMOKU_HOME`
(default `~/.gomoku`), `BUILD_DIR` (default `./build`). All cargo
builds share one target directory under `BUILD_DIR` so the Burn deep
learning stack compiles once.

`make install` performs: fetch both repositories at their pins →
`cargo install --locked` of `nettrain` (with the `gpu` feature, for
the wgpu/Metal device), the `gomoku` terminal frontend, and
`gomoku-gui` → install the scripts from [scripts/](scripts/) → write
`~/.gomoku/config.json` if absent (never overwrites). Existing
installations are updated in place (`--force`); `make uninstall`
removes exactly what was installed.

## The installed tools

- `nettrain` — the training authority (rust-ml `net` crate).
- `gomoku` — the terminal frontend: play and analyze on either board
  (rust-ml `cli` crate).
- `gomoku-gui` — the native macOS application.
- `nettrain-wgpu` — convenience script: train on the wgpu device
  against the `synthetic/v0` dataset. Resolves its data root from
  `GOMOKU_DATA`, falling back to `./data` relative to the current
  working directory:

  ```sh
  cd ~/my-lab                    # a working directory
  GOMOKU_DATA=./data nettrain-wgpu --steps 5000
  ```

## Development workflow

Development happens in the source repositories as before. Shipping a
new state to the lab is a deliberate act: push gomoku-gui (whose
`Cargo.toml` carries the matching rust-ml revision), bump `rev` in
[gmklabs.toml](gmklabs.toml), run `make install`.

## Status

Initial version. Known limits:

- Installed binaries do not yet embed their source revision, so
  `make doctor` checks presence and configuration but cannot yet prove
  rev equality. Version stamping in the binaries is planned.
- The GUI's lab configuration (the `.gomoku` directory) is specified
  by gomoku-gui's lab-explorer spec with a `./.gomoku` default; moving
  that default to `~/.gomoku` is a future gomoku-gui change, tracked
  there.

## References

- [rust-ml](https://github.com/Project-Ellie/rust-ml) — rules engine,
  MCTS search, training pipeline.
- [gomoku-gui](https://github.com/Project-Ellie/gomoku-gui) — the
  native application and future training laboratory; its
  `docs/specs/2026-11-08-gomoku-gui-lab-design.md` specifies the lab,
  `docs/specs/2026-11-09-lab-explorer-design.md` the `.gomoku`
  configuration directory.
- [gmklabs.toml](gmklabs.toml) — the gomoku-gui pin.
- [Makefile](Makefile) — the installer.
