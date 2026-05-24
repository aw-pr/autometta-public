---
name: feedback-tick-respawns-verifier-while-worker-running
description: tick.sh has no check for whether the worker process is still running. It spawns the verifier on every tick that sees in_progress + no artefact, stacking processes.
metadata:
  type: feedback
---

`scripts/tick.sh::process_repo` on an `in_progress` stage:

```sh
artefact="$(state_json ... | jq -r '... .verifier_artefact // empty')"
if [[ -n "$artefact" && -f "$repo_root/$artefact" ]]; then
  # promote to completed
else
  # dispatch verifier
fi
```

There is no check whether the worker is still running. If the worker takes longer than the cron tick interval (which is typical: workers take minutes, ticks fire every few minutes), every subsequent tick sees `current_stage = in_progress`, `verifier_artefact = absent`, and fires another verifier. After N ticks during a long worker run, there are N verifier processes racing the worker.

There is also no check whether a previous verifier is still running. Same stacking applies on the verifier side.

**Why:** Surfaced while preparing the stage 6 dispatch test. Before authoring the test card, the orchestrator traced tick.sh's branches and noticed the unconditional verifier dispatch.

**How to apply:** Two guards needed before the verifier dispatch:

1. Worker-still-running guard:
   ```sh
   if [[ -n "${worker_pid:-}" ]] && kill -0 "$worker_pid" 2>/dev/null; then
     log "worker ${worker_pid} for ${current_stage} still running, skipping verifier dispatch"
     return 0
   fi
   ```

2. Verifier-already-spawned guard: track verifier_pid in state.yaml (spawn-verifier.sh already writes it). Before dispatching, check if verifier_pid is set and the process is alive; if so, skip.

The existing stage-5a elapsed-time stall detection partly mitigates this (a stuck worker eventually trips the stall and the loop moves on), but stall only fires at budget + 50% grace. In the meantime multiple verifier processes have already spawned.

Cross-reference: [[feedback-verifier-dispatch-impoverished]] (the verifier prompt itself is also broken; both gaps need fixing together before stage 6 can run a real dispatch test); [[decision-tick-implementation-parameters]].
