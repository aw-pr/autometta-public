# Synthetic worker SDK stage A

- Stage id: worker-sdk-stage-A
- Expected handoff status: pass

## Deliverables

- `deliverable.txt`, containing exactly `stage A completed` followed by a newline.
- `handoff.json`, written by you with this exact shape:

```json
{
  "stage_id": "worker-sdk-stage-A",
  "status": "pass",
  "deliverables": ["deliverable.txt", "handoff.json"],
  "notes": "Stage A created the in-tree deliverable.",
  "worker_identity": "Claude Agent SDK experiment <claude-agent-sdk@local>"
}
```

Use file tools only. Do not use Bash.
