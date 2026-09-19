# frozen_string_literal: true

# Idempotent setup for the "Goodmarket Assistant" Captain::Assistant, its
# guardrails, its link to the storefront widget's inbox, and the two Custom
# Tools it calls on the `assistant` backend service (order status, account
# info). See goodness/README.md for when to run this and why it exists at
# all — in short: this is DATA, not code, so a fresh Chatwoot install or a
# CAPTAIN_TOOL_SECRET rotation needs this script re-run, not just a deploy.
#
# Usage (as the chatwoot user, with the account's own env sourced):
#   CAPTAIN_TOOL_SECRET="$(cat the value from shared/assistant.env)" \
#     bundle exec rails runner goodness/setup_captain.rb
#
# Safe to re-run: every step is find_or_initialize_by + assign_attributes, so
# re-running after an edit here updates the existing records rather than
# duplicating them.

ACCOUNT_ID = 1
INBOX_NAME = "Goodmarket storefront"
TOOLS_BASE_URL = "https://api-staging.goodmarket.africa"

account = Account.find(ACCOUNT_ID)
token = ENV.fetch("CAPTAIN_TOOL_SECRET") do
  abort "CAPTAIN_TOOL_SECRET is not set — same value as goodmarket.backend's shared/assistant.env"
end

# ── Feature flags — both required, independently (captain-conventions.md has
# the reasoning: captain_integration_v2 is the assistant engine, custom_tools
# is the tool-calling capability, and neither implies the other) ────────────
#
# Both are premium (`enterprise/config/premium_features.yml`), and Chatwoot's
# own `Enterprise::Billing::ReconcilePlanFeaturesService` — triggered by any
# Stripe billing event this install ever processes — DISABLES every premium
# feature first and only re-enables what the account's plan_name entitles it
# to. We have no plan_name (self-hosted, no subscription), so a reconcile run
# turns both straight back off with no warning. Observed live: on 2026-09-19,
# on within a few hours of being enabled.
#
# `manually_managed_features` is Chatwoot's own escape hatch for exactly this
# — it is re-applied as the LAST step of that same reconcile, after the
# plan-based enable/disable, so it survives future runs instead of being
# silently reverted again. Only `custom_tools` can go in this list (its
# validator checks against BUSINESS_PLAN_FEATURES + ENTERPRISE_PLAN_FEATURES
# — captain_integration_v2 isn't a member of either, Chatwoot decides IT
# separately via `captain_v2_default_eligible?`, which for a self-hosted
# account with no `plan_name` currently comes out true; if that ever flips
# back off, `account.internal_attributes['captain_v2_default_eligible']`
# would need setting to `true` explicitly instead).
internal_attrs = Internal::Accounts::InternalAttributesService.new(account)
internal_attrs.manually_managed_features =
  (internal_attrs.manually_managed_features + %w[custom_tools]).uniq
account.enable_features!("captain_integration_v2", "custom_tools")

# ── The assistant itself ─────────────────────────────────────────────────────
assistant = Captain::Assistant.find_or_initialize_by(account: account, name: "Goodmarket Assistant")
assistant.assign_attributes(
  description: "Answers shopper questions about the Goodmarket marketplace: orders, delivery, account. Nothing else.",
  guardrails: [
    "Only answer questions about Goodmarket: products, orders, delivery, payments (Goodpay), accounts and how the marketplace works.",
    "Refuse anything unrelated to Goodmarket — general knowledge, other companies, personal advice, coding help — and say this assistant only handles Goodmarket questions.",
    "Never invent an order status, a delivery date or an account detail. If a tool answers not_signed_in, tell the shopper to sign in first. If a tool answers not_found, say so plainly rather than guessing.",
    "Never ask for or accept a password, OTP code or payment card number in the chat.",
    "Block queries that share or request sensitive personal information (e.g. phone numbers, passwords).",
    "Reject queries that include offensive, discriminatory, or threatening language.",
    "Deflect when the assistant is asked for legal or medical diagnosis or treatment."
  ],
  response_guidelines: [
    "Be concise and friendly, in the shopper's own language (French or English).",
    "When a tool returns order or account details, summarize them in plain language rather than dumping raw fields.",
    "If unsure, say so and offer to connect the shopper with a human agent rather than guessing."
  ],
  # Dormant capabilities, now turned on:
  #   feature_contact_attributes — lets Captain use the contact's own custom
  #     attributes (city, locale, country, currency, delivery — already set
  #     by the storefront widget) as context. This is exactly ticket 0142's
  #     "context arrives by ownership" argument, just switched on.
  #   feature_faq       — background job proposes FAQ entries from resolved
  #     conversations, for a human to review (Captain > FAQs > pending).
  #   feature_memory     — after a conversation resolves, Captain writes a
  #     contact note summarizing it, for the next agent who opens the thread.
  #   feature_citation   — cites the source document in an answer; a no-op
  #     until Captain > Documents has something crawled, harmless either way.
  # Merged, never replaced: config already carries auto_resolve_mode et al.,
  # and a plain `config: {...}` assignment would wipe that out on every rerun.
  config: assistant.config.merge(
    "feature_contact_attributes" => true,
    "feature_faq" => true,
    "feature_memory" => true,
    "feature_citation" => true
  )
)
assistant.save!
puts "assistant id=#{assistant.id} guardrails=#{assistant.guardrails.size}"

# ── Link it to the storefront widget's inbox ────────────────────────────────
inbox = Inbox.find_by!(account: account, name: INBOX_NAME)
captain_inbox = CaptainInbox.find_or_initialize_by(inbox: inbox)
captain_inbox.captain_assistant = assistant
captain_inbox.save!
puts "captain_inbox inbox=#{captain_inbox.inbox_id} assistant=#{captain_inbox.captain_assistant_id}"

# ── The two Custom Tools ─────────────────────────────────────────────────────
# Account-scoped, not assistant-scoped (Chatwoot's own model) — every enabled
# custom tool on the account is automatically available to every assistant on
# it. `endpoint_url` MUST be a real HTTPS hostname: Chatwoot's
# SafeEndpointValidatable concern hard-rejects an IP or plain HTTP, with no
# override. TOOLS_BASE_URL reuses api-staging.goodmarket.africa's existing
# vhost (see DEPLOYMENT.md) rather than a dedicated subdomain — its `/tools/*`
# regex location is the second exception to "the gateway is the only door",
# the same shape as the payment webhooks' first one.

order_status = Captain::CustomTool.find_or_initialize_by(account: account, title: "Order status")
order_status.assign_attributes(
  description: "Look up the status, items and delivery info of a Goodmarket order belonging to the signed-in shopper asking. Only works for a verified, signed-in shopper; refuses otherwise.",
  endpoint_url: "#{TOOLS_BASE_URL}/tools/order-status",
  http_method: "POST",
  auth_type: "bearer",
  auth_config: { token: token },
  param_schema: [
    { name: "order_code", type: "string", description: "The order's code/reference as the shopper gave it", required: true }
  ],
  request_template: '{"order_code": "{{ order_code }}"}',
  enabled: true
)
order_status.save!
puts "order_status id=#{order_status.id} slug=#{order_status.slug}"

account_info = Captain::CustomTool.find_or_initialize_by(account: account, title: "Account info")
account_info.assign_attributes(
  description: "Look up the signed-in shopper's own Goodmarket account profile (name, email, phone). Only works for a verified, signed-in shopper; refuses otherwise.",
  endpoint_url: "#{TOOLS_BASE_URL}/tools/account-info",
  http_method: "POST",
  auth_type: "bearer",
  auth_config: { token: token },
  param_schema: [],
  enabled: true
)
account_info.save!
puts "account_info id=#{account_info.id} slug=#{account_info.slug}"
