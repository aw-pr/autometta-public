#!/usr/bin/env bash
# rates.sh — single source of truth for the cost-estimation rate table that
# turns parsed token counts into the cost_usd_est field of a cost-log line
# (see docs/cost-log.md). This is the ONE place to edit when list prices move
# or a new tier is added; cost-log.sh sources this file and nothing else
# carries rate numbers of its own.
#
# Two mappings live here:
#   1. tier_for_identity  — an agent identity string -> capability tier
#      (T1 / T2 / T4), matching the agent-orchestrator skill's tier table.
#   2. rate_for_tier      — a tier -> "INPUT CACHED OUTPUT" USD per million
#      tokens.
#
# Rates are list-price ESTIMATES, not invoices. They give FinOps a stable,
# comparable cost_usd_est per role; reconcile against the real provider bill
# for ground truth. Cached-input is the cache-read rate (~10% of input on the
# Anthropic API). Cache-creation (write) tokens are folded into input_tokens
# upstream and billed at the input rate, which slightly under-estimates the
# ~1.25x write premium — acceptable for an estimate, documented in
# docs/cost-log.md.
#
# bash 3.2 compatible: case statements only, no associative arrays.

# Map a worker/verifier identity string to a capability tier.
#
# Tiers follow skills/agent-orchestrator/SKILL.md:
#   T0 - frontier-above-Opus (Claude Fable 5) - opt-in per card only
#   T1 - frontier reasoning (Opus, GPT-5.6 Sol, Gemini Pro)
#   T2 - workhorse         (Sonnet, GPT-5.6 Terra)
#   T4 - light             (Haiku, GPT-5.6 Luna)
#   T5 - local weights     (Codex GPT-OSS 120B, on-machine Ollama) - $0 explicit
# T0 was previously reserved for the orchestrator's own main session, which is
# not a dispatched role and is not costed here. It now labels the opt-in Fable
# tier, the sole dispatched role above Opus; no existing identity resolves to it.
# T5 exists so a local identity gets an explicit $0 row rather than falling
# through to the T2 default below, which would cost a free dispatch at the
# $3/M workhorse rate: a local run's own point is that it does not do that.
# Falls back to T2 when no tier marker matches, so an unknown identity is
# costed at the workhorse rate rather than silently free.
tier_for_identity() {
  local identity="$1"
  # Both forms are matched: the human identity string ("Claude Fable 5")
  # and the raw model id ("claude-fable-5"), because the advisor tier is
  # resolved from the model id emitted on verify-sdk's `advisor:` line.
  case "$identity" in
    *Fable*|*fable*)   printf 'T0\n' ;;
    *Opus*|*opus*)     printf 'T1\n' ;;
    *GPT-5.6\ Sol*|*gpt-5.6-sol*) printf 'T1\n' ;;
    *Gemini\ Pro*)     printf 'T1\n' ;;
    *Haiku*|*haiku*)   printf 'T4\n' ;;
    *GPT-5.6\ Luna*|*gpt-5.6-luna*) printf 'T4\n' ;;
    *mini*)            printf 'T4\n' ;;
    *Flash*|*flash*)   printf 'T4\n' ;;
    *GPT-OSS*|*gpt-oss*) printf 'T5\n' ;;
    *Llama*|*llama*)   printf 'T5\n' ;;
    *Sonnet*|*sonnet*) printf 'T2\n' ;;
    *GPT-5.6\ Terra*|*gpt-5.6-terra*) printf 'T2\n' ;;
    *GPT-5*|*gpt-5*|*Codex*|*codex*) printf 'T2\n' ;;
    *)                 printf 'T2\n' ;;
  esac
}

# Print "INPUT CACHED OUTPUT" USD per one million tokens for a tier.
# Unknown tiers fall back to the T2 row.
rate_for_tier() {
  local tier="$1"
  case "$tier" in
    T0) printf '10.0 1.0 50.0\n' ;;
    T1) printf '15.0 1.5 75.0\n' ;;
    T2) printf '3.0 0.3 15.0\n' ;;
    T4) printf '1.0 0.1 5.0\n' ;;
    T5) printf '0.0 0.0 0.0\n' ;;
    *)  printf '3.0 0.3 15.0\n' ;;
  esac
}
