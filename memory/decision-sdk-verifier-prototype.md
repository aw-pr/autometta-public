# Decision

Use a Python Claude Agent SDK prototype for verifier output before changing `scripts/spawn-verifier.sh`.

# Why

`claude -p` remains the production verifier path, but it has awkward headless behaviour for autometta: output is not streamed until completion, and one permission-mode combination exits silently. The Agent SDK is the programmatic surface for the same family, so it is the right thing to probe before changing dispatch.

Python is the first prototype language because autometta's dispatch shell can call it directly, the repo already treats shell scripts and Markdown as the product surface, and a single-file Python wrapper keeps dependency installation to `pip install -r scripts/requirements-sdk.txt`. A TypeScript port would add a second toolchain before the verifier contract is proven.

This stays prototype-only because the risk is in the integration boundary, not the JSON envelope. The SDK route still needs auth-route handling, budget accounting, liveness registration, and state transitions before it can replace or sit beside `claude -p`.

# How to apply

Run `scripts/verify-sdk.py` manually with an API key injected by `op-fetch`. Treat its output as a smoke-test artefact, not a production verifier result, until a later card wires it into the spawn path.

This builds on [[decision-auth-route-toggle]]: auth remains the caller's job, and the script only reads `ANTHROPIC_API_KEY` from its environment.
