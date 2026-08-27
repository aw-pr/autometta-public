# Stage card 78: the docs catch up with the instrumentation

## Metadata

- **Authored:** 2026-08-27
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Base branch:** dev
- **Run branch:** autometta/78-the-docs-catch-up-with-the-instrumentation
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Pairing rationale:** prose for operators is display work by another
  name; the premium pair keeps it. Cross-family, verified by the family
  that did not write it.

## Objective

Cards 60 to 77 changed what an operator has, and the docs do not know
it. A full drift review on 2026-08-27 (dev at cf7377c) found the TUI in
zero tracked documents, eleven live subcommands missing from the
MANUAL's supposedly complete CLI table, and six factual claims now
false. This card lands the corrections, the missing narrative, and the
version history. The findings below are the review's, verified against
the tree at review time; re-verify a pointer before acting on it, and
correct anything the review itself got stale.

## Inputs (read these in your own context)

- `README.md`, `MANUAL.md`, `docs/setup.md`, `docs/tick-loop.md`,
  `docs/observability.md`, `docs/lessons.md`, `docs/dashboard.md`,
  `CLAUDE.md`.
- `bin/autometta` usage block, the ground truth for the CLI table.
- `docs/verifier-bake-off.md` for the candidate count and llama row.
- `docs/incidents/2026-08-27-the-llama-bake-off-overnight.md`, this
  batch's story, for cross-linking.
- `docs/PUBLISH-WORKFLOW.md:51` for the release conventions.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. **Stale claims corrected** (the review's (a) list):
   - README.md:85 "no observability" clause removed; :47 and :162-165
     `examples/self-host/` references replaced by `stage-cards/` and
     the layout tree gains `stage-cards/`; :151-154 scripts comment
     refreshed; :257-278 "seven candidates" becomes eight with
     `local-llama4-scout` added to the do-not-trust list.
   - MANUAL.md CLI table gains the eleven missing subcommands (`tui`,
     `check-build`, `refresh-repo`, `refresh-all-repos`,
     `phat-controller`, `controller-seed`, `drain`, `retro-grade`,
     `panel`, `install-launchagent-phat-controller`,
     `uninstall-launchagent-phat-controller`), each row checked
     against `bin/autometta`; :197-198 status list gains
     `superseded`; :115 tick row notes pipeline pairs.
   - docs/setup.md:262,288 candidate count corrected; `autometta tui`
     joins the operator surfaces; `autometta check-build` joins
     section 5's verification steps.
   - docs/tick-loop.md:529 future-scope line rewritten to point at the
     shipped TUI; :216 attach description aligned with the current
     two-window layout.
   - docs/lessons.md:336 gains the "(now `stage-cards/PLAN.md`)"
     parenthetical.
   - CLAUDE.md and README.md:93 loop descriptions gain the one-clause
     pipeline-pair amendment.
2. **The TUI narrative**: a Feature status row in README; a MANUAL
   section 6 subsection (pages, keys, capture mode, the data seam); a
   paragraph in docs/observability.md; dashboard.md names the TUI as a
   consumer and notes the card-74 seam speedup as why the 5-second
   poll is honest.
3. **The operator-surface ladder**: a short "What an operator now has"
   subsection in docs/observability.md joining `autometta status`, the
   tickers, `autometta tui`, `autometta failures`, the HTML dashboard,
   and the controller inbox, one sentence each with the reach-for rule.
4. **run_id documented**: two sentences in docs/tick-loop.md section
   (b) and the MANUAL add-stage row.
5. **Stale-build guidance**: README's "Updating an existing repo"
   section says the surfaces now warn, names `autometta check-build`.
6. **Version history**: a `## Version history` table at the bottom of
   README.md (above Licence) with v0.1.0 (2026-05-29, first tagged
   release: dispatch contract, tick loop, unattended launchd path) and
   v0.2.0 (2026-08-27, operator instrumentation: TUI, pipeline pairs,
   run_id, stale-build warning, seam speedup, bake-off completed
   across eight candidates). Do not create the git tag; the
   orchestrator tags v0.2.0 at landing.

## Constraints

- Docs only. No script, schema, or template changes.
- Every corrected claim is verified against the tree, not against this
  card; where the review's pointer has drifted, follow the tree and
  note it in the envelope.
- British English, no em dashes, no AI-tell vocabulary (delve,
  leverage, seamless, robust). The persona-west audit rules apply.
- HANDOFF.md is out of scope (private tier, separately maintained).
- Do not renumber or restructure documents; smallest edit that makes
  the claim true.

## Acceptance criteria

1. Every (a)-list item above is corrected, shown as a per-file
   before/after in the handoff.
2. `grep -rl "tui" README.md MANUAL.md docs/*.md` is no longer empty:
   the TUI appears in README's feature table, the MANUAL, and
   observability.md at minimum.
3. The MANUAL CLI table covers every subcommand in `bin/autometta`'s
   usage block, verified by listing both sets side by side.
4. `grep -rn "examples/self-host" README.md MANUAL.md docs/*.md`
   returns only deliberate historical references with a "since moved"
   note, or nothing.
5. The candidate count reads eight everywhere the bake-off is
   summarised, and llama4-scout appears in the do-not-trust list with
   its 0% FAIL recall.
6. The version-history table exists with both entries; no git tag was
   created.
7. The operator-surface ladder section exists and names all six
   surfaces.
8. No em dashes were added to any touched file (`git diff` audited),
   and touched prose passes the vocabulary rules.
9. `git status` shows changes only to the eight documents named in the
   inputs list.

## Contract test

After the edits: the MANUAL CLI set equals bin/autometta's usage set;
the four greps in criteria 2, 4, 5 and 8 return the stated results;
the version table renders with two rows; the diff touches only the
named documents.

## Out of scope

- Creating the v0.2.0 git tag (orchestrator, at landing).
- HANDOFF.md.
- Any code, schema, or behaviour change.
- The explainer article and the incident narrative (already landed).

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the per-file before/after list, the CLI-table side-by-side, the
four grep outputs, the version table, and the diff summary showing
only the named files.

## Family-specific notes

None
