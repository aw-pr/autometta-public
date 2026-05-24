---
name: feedback-init-script-macos-specific
description: scripts/init-host.sh:25 uses macOS/BSD-specific stat -f '%Lp' for reading directory permissions. Not a defect on macOS (the stated target) but blocks Linux portability.
metadata:
  type: feedback
---

`scripts/init-host.sh` line 25 reads directory permissions with `stat -f '%Lp' "$controller_home"`. The `-f '%Lp'` format is macOS/BSD-specific. The GNU `stat` on Linux uses `stat --format='%a' "$controller_home"`. On Linux the BSD form produces an empty string and the chmod guard always fires; behaviour is degraded but not catastrophic.

**Why:** The autometta self-host target is currently macOS only per `docs/philosophy.md` (Linux "should work" but is not tested). The stage-5b verifier flagged this as out of scope for the stated target but worth tracking. Banking now so a future Linux port has a head start.

**How to apply:** When Linux support enters scope, replace the line with a portability branch such as:

```sh
if [[ "$(uname -s)" == "Darwin" ]]; then
  current_mode="$(stat -f '%Lp' "$controller_home")"
else
  current_mode="$(stat --format='%a' "$controller_home")"
fi
```

Or use a `python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$controller_home"` cross-platform substitute.

Cross-reference: [[feedback-stage-5-silent-failure-risks.md]].
