# Stage card 88: the machine dependencies are declared

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/88-the-machine-dependencies-are-declared
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Path claims:** docs/machine-dependencies.md
- **Pairing rationale:** an inventory needs breadth of reading, not deep
  judgement, so the Claude workhorse tier writes it and the codex verifier
  re-runs the probe commands from outside the sandbox. The Claude worker also
  alternates families with the codex workers either side of this card in the
  queue, which is what lets the pipeline pair engage.

## Objective

The UAT feedback asks for a review of everything this repo assumes about the
machine but does not ship: "we must assume that codex and claude are
installed, what about ollama and any bespoke scripts like my token usage
ones". A fresh clone on a new laptop fails in ways no doc predicts, because
the dependency surface has grown by accretion: vendor CLIs, Homebrew tools,
scripts living under the operator's home directory, XDG config files,
LaunchAgents, and a 1Password service account.

Produce the declared inventory: every non-git-hosted dependency, what breaks
without it, and whether anything already probes for it.

## Inputs (read these in your own context)

- scripts/ (grep for external commands and home-directory paths; read what
  the grep points at, not every file)
- bin/autometta
- docs/setup.md
- templates/launchagent.plist.tpl

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `docs/machine-dependencies.md`, at most 1000 words plus one table. The
   table has one row per dependency with four columns: what it is, where it
   comes from (brew formula, vendor installer, operator's own scripts, XDG
   config, 1Password), what fails without it and how loudly (fail-closed
   with a named error, or silent degradation), and whether `check-deps` or
   an auth probe already covers it. Prose before the table states the
   discovery method so the next audit can repeat it; prose after it lists
   the gaps: every dependency whose absence fails silently or late, worst
   first.

## Constraints

- Inventory by evidence: a dependency enters the table because a script in
  this repo invokes or reads it, with the invoking path named in the row.
  Nothing enters from memory of how the operator's machine happens to look.
- Do not modify any script, including `check-deps`. Closing the gaps is a
  later card; this one declares them.
- No absolute home-directory paths in the document: write `~/Scripts/op-fetch`
  style paths.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `docs/machine-dependencies.md` exists, is at most 1000 words plus the
   table, and has the three parts described above.
2. Every table row names the repo path that invokes or reads the dependency;
   the verifier traces at least five rows to their invoking line.
3. The vendor CLIs (`claude`, `codex`), `ollama`, `op`, `op-fetch`, `yq`,
   `jq`, `tmux`, the XDG op-refs file, the 1Password service-account env
   file, and the LaunchAgent plists all appear. Absence of any is a failure.
4. The gaps list is non-empty and each entry states how the absence
   manifests today.
5. `git status --porcelain` in the run worktree shows changes confined to
   `docs/machine-dependencies.md`.
6. `grep -c '—' docs/machine-dependencies.md` returns 0 and no `/Users/`
   path appears in the document.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Extending `check-deps` or any spawn preflight to cover the gaps.
- The herdr evaluation (card 87) and anything about session multiplexers.
- Dependencies of subscribed repos other than this one.

## Budget

- **Worker wall-clock:** 2400s
- **Verifier wall-clock:** 1800s

## Verifier handoff

Leave the working tree dirty. Report the row count, the five traced rows with
their invoking lines, and the gaps list verbatim.

## Family-specific notes

None
