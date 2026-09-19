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
account.enable_features!("captain_integration_v2", "custom_tools")

# ── The assistant itself ─────────────────────────────────────────────────────
assistant = Captain::Assistant.find_or_initialize_by(account: account, name: "Goodmarket Assistant")
assistant.assign_attributes(
  description: "Answers shopper questions about the Goodmarket marketplace: orders, delivery, account. Nothing else.",
  guardrails: [
    "Only answer questions about Goodmarket: products, orders, delivery, payments (Goodpay), accounts and how the marketplace works.",
    "Refuse anything unrelated to Goodmarket — general knowledge, other companies, personal advice, coding help — and say this assistant only handles Goodmarket questions.",
    "Never invent an order status, a delivery date or an account detail. If a tool answers not_signed_in, tell the shopper to sign in first. If a tool answers not_found, say so plainly rather than guessing.",
    "Never ask for or accept a password, OTP code or payment card number in the chat."
  ],
  response_guidelines: [
    "Be concise and friendly, in the shopper's own language (French or English).",
    "When a tool returns order or account details, summarize them in plain language rather than dumping raw fields.",
    "If unsure, say so and offer to connect the shopper with a human agent rather than guessing."
  ]
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
