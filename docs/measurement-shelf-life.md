# Measurement shelf life

Some claims in this repo describe third-party behaviour observed at a point in
time, not guarantees made by our own code. They include provider prices and
limits, available model identifiers, free-tier rosters, CLI acceptance or
refusal behaviour, model capabilities reported by local runtimes, and measured
latency or quality results produced through those dependencies.

Such claims expire when any part of the observed route changes. A CLI or local
runtime upgrade can add a new capability gate. Providers can rotate models,
change prices or limits, or alter API behaviour. A model can be removed,
retagged or replaced while its identifier remains in prose. Machine state can
also drift when weights are removed or a local service is stopped. A date
records when a measurement was true; it does not make the claim current.

The verifier bake-off is the worked example. Its candidate scores remain the
historical result measured on 2026-08-24. Three days later, Codex CLI refused
four of the documented local candidates because their Ollama metadata lacked
the `thinking` capability now required by `codex exec --oss`. The figures did
not become false, but most local rows stopped being reproducible.

When an agent finds an expired measured claim, it should preserve the original
figures and date, record the changed dependency and current evidence in a
caveat, and link to a cheap repeatable viability check where one exists. For
the bake-off, run `scripts/candidate-viability.sh` before attempting a local
candidate. If current evidence changes the recommendation rather than merely
its reproducibility, open a separately scoped measurement stage. Do not
silently rewrite historical results, spend tokens to prove a fact available
from local metadata, or turn a check into a scheduled job without an explicit
operator decision.
