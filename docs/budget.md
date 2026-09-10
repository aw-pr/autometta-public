# Budget drains

A budget drain is a temporary host-level decision to raise the token cap for a deliberate run. It is stored as one `drain.json` document under the controller home and never changes a subscriber's resting `budget.json`, daily runaway cap, or window reserve configuration.

## Starting and joining a drain

`drain start` creates a drain when none is active. A repeated start does not silently revoke the drain already in force.

A new request joins the active drain when all of these conditions hold:

- its token cap is identical;
- its `--ignore-reserve` setting is identical; and
- its requested expiry is the same as or later than the active drain's expiry.

The joined drain uses the union of both repo scopes and retains the original expiry. An empty scope means all subscribers, so its union with any scoped request remains all subscribers. Keeping the original expiry ensures that adding a repo cannot extend the authority already granted to another repo. Refusing an earlier requested expiry ensures that it cannot shorten another repo's drain either.

If the cap, reserve setting, or expiry is incompatible, `drain start` exits non-zero. It prints the active drain's cap, expiry, and scope, then tells the operator that `--replace` is required. The active file is left unchanged.

`--replace` is the explicit destructive choice. It replaces the cap, expiry, scope, reason, and reserve setting with the new request. Use it only when revoking the active drain is intended.

## Scope and status

A populated `repos` array is an allow-list of absolute subscriber repo paths. An empty or absent array covers every subscriber, preserving the meaning of existing version 1 files.

`drain status` prints the raw scope and resolves it against the enabled subscriber registry. It names covered and uncovered subscribers separately, so an active drain cannot be mistaken for a fleet-wide drain.

## Expiry and locking

The first budget read after `expires_at` retires `drain.json` to `drain.expired.json` and returns to the resting cap. Drain starts, explicit ends, and expiry retirement share a host-level lock, preventing one operation from moving or overwriting a newer drain while concurrent callers are acting on the same document.
