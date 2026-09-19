# Goodness's own scripts

Everything under `goodness/` is ours, not upstream Chatwoot's — kept in one place so a diff against
`upstream/develop` stays readable and nothing here is mistaken for a Chatwoot file.

- `setup_captain.rb` — creates (or updates, idempotently) the "Goodmarket Assistant" Captain::Assistant,
  its guardrails, the CaptainInbox link to the storefront widget's inbox, and the two Custom Tools
  (order status, account info) that call the `assistant` backend service. Full context:
  `goodmarket.backend/docs/tickets/0157-*.md` and `DEPLOYMENT.md`'s "Captain — the AI assistant" section.

  Run it with `rails runner goodness/setup_captain.rb` as the `chatwoot` user, with `CAPTAIN_TOOL_SECRET`
  in the environment (never hardcoded here — it is the same value as
  `goodmarket.backend`'s `shared/assistant.env`). Needed after a fresh install, and after rotating
  `CAPTAIN_TOOL_SECRET` (re-run to push the new token into both Custom Tools).

  This script is **data**, not code: nothing in a `git pull` recreates the Assistant, its guardrails or
  the Custom Tools — they live in Chatwoot's own Postgres, not in this repo. Re-running the script is
  what makes them exist again on a new instance.
