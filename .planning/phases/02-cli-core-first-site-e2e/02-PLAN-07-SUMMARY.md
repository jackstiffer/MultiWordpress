---
phase: 02-cli-core-first-site-e2e
plan: 07
subsystem: docs
tags: [docs, runbook, cloudflare, cache, validation]
requires: [02-03, 02-05, 02-06]
provides: ["Operator runbook for first-domain E2E validation"]
affects: ["docs/first-site-e2e.md"]
tech-stack:
  added: []
  patterns: [runbook, sign-off-checklist]
key-files:
  created: ["docs/first-site-e2e.md"]
  modified: []
decisions:
  - "Wildcard hostname match (*.dirtyvocal.com) called out as alternative to per-host equals match — saves a Cache Rule per new sub-site in same zone"
  - "Sign-off checklist matches the 8 acceptance points in plan task spec verbatim — operator attestation goes into 02-VERIFICATION.md"
metrics:
  duration: "~6 minutes"
  completed: "2026-04-30"
---

# Phase 2 Plan 07: First-Site E2E Runbook Summary

Shipped `docs/first-site-e2e.md` — the operator runbook that turns Phase 2
success criterion #5 ("first real domain proves the cache promise") into a
checkable, repeatable workflow.

## What's in the file

**361 lines** of clean markdown, structured as:

1. Title + purpose (criterion #5 framing, ~20–30 min total time)
2. Prerequisites table (8 rows: Phase 1 infra, wp.slice, CLI on PATH, Caddy,
   Cloudflare, host secrets, spare domain, VM IP)
3. **Step 1** — `wp-create <domain>` with sample anonymized output and
   `--resume` recovery hint
4. **Step 2** — Cloudflare DNS row (Proxied / orange cloud, `dig` verify)
5. **Step 3** — paste Caddy block, reload Caddy in place
6. **Step 4** — Cloudflare Cache Rule (one-time per zone) with all 5 cookie
   bypasses verbatim and APO anti-pattern call-out
7. **Step 5** — Super Page Cache plugin install via `wp-exec`
8. **Step 6** — validation curls (cold MISS → warm HIT, logged-in BYPASS,
   TTFB measurement)
9. **Step 7** — isolation check (wp.slice memory ceiling, AudioStoryV2 health,
   container CgroupParent)
10. **Step 8** — CLI sanity check (`wp-list`, `wp-stats`, `wp-logs`)
11. **Troubleshooting** — 10-row table covering the failure modes called out
    in the plan plus 5 additional ones surfaced from PITFALLS.md (522 / MTU,
    502, cf-cache-status DYNAMIC, BYPASS-when-logged-out, slow TTFB, LE cert
    failure with Cloudflare SSL mode, redis-cache not active, UID mismatch,
    WooCommerce cart, plugin install network)
12. **Sign-off checklist** — 8 boxes matching the plan spec
13. **Repeating for additional domains** — concise reuse guide
14. **References** — links to template, cli.md, CONTEXT, PITFALLS, ROADMAP

## Compliance with plan verification

| Verify check | Result |
| --- | --- |
| File exists | ✓ |
| ≥ 100 lines | ✓ (361) |
| Contains `cf-cache-status` | ✓ (14 occurrences) |
| Contains `wordpress_logged_in_` | ✓ (4) |
| Contains `super-page-cache-for-cloudflare` | ✓ (2) |
| Contains `wp-create` | ✓ (11) |
| Contains `wp-exec` | ✓ (6) |
| Contains `Troubleshooting` (case-insensitive) | ✓ (3) |
| References `cloudflare-cache-rule.md` | ✓ (3 references / 3 mentions) |
| All 3 cookie patterns named verbatim | ✓ (`wordpress_logged_in_`, `wp-postpass_`, `comment_author_`) |

## Deviations from plan spec

**None of substance.** Two minor enhancements:

1. **Step 4 expanded to 5 cookies, not 3.** PITFALLS.md §7.1 and the existing
   `templates/cloudflare-cache-rule.md` template both list
   `woocommerce_items_in_cart` and `woocommerce_cart_hash` alongside the
   three core WP cookies. I included them in the runbook for parity with the
   canonical template and to head off the WooCommerce empty-cart failure
   mode the plan's troubleshooting list anticipates. (Rule 2: missing
   functionality from the canonical reference.)

2. **Troubleshooting table has 10 rows, not the 5 the plan suggested as
   minimum.** Plan spec said "5 rows minimum"; verification said "≥ 4 rows".
   I kept all 5 plan-specified rows verbatim and added 5 more from
   PITFALLS.md / common WP-Cloudflare failure modes (MTU 522, slow TTFB,
   LE/SSL mode, WooCommerce cart, plugin install network). No deviation
   from the spec — strict superset.

3. Added "Repeating for additional domains" section (item 11 in plan spec)
   that explicitly notes wildcard hostname matches in Cache Rules cover
   new sub-sites automatically, saving the operator a per-domain Cache Rule
   in the same zone. This is a small clarification on top of the plan
   spec's "Cache Rule per-domain" wording.

## Operator action required

This is a **documentation-only** deliverable. Phase 2 success criterion #5 is
**not** satisfied by shipping this file — it's satisfied when the operator
runs through the runbook on the actual VM (`dirtyvocal-nextjs`), observes the
expected `cf-cache-status: HIT` / `BYPASS` outcomes, ticks the 8-point
checklist, and records the attestation in
`.planning/phases/02-cli-core-first-site-e2e/02-VERIFICATION.md`.

The Phase 2 verifier confirms criterion #5 by reading that VERIFICATION.md
entry, not by re-running the runbook.

## Self-Check: PASSED

- FOUND: docs/first-site-e2e.md (361 lines)
- FOUND: required strings (cf-cache-status, all 3 cookie patterns,
  super-page-cache-for-cloudflare, wp-create, wp-exec, Troubleshooting,
  cloudflare-cache-rule)
- FOUND: template reference link to `templates/cloudflare-cache-rule.md`
