module Enterprise::Inbox
  def member_ids_with_assignment_capacity
    return super unless enable_auto_assignment?
    return filter_by_capacity(available_agents).map(&:user_id) if auto_assignment_v2_enabled?

    max_assignment_limit = auto_assignment_config['max_assignment_limit']
    overloaded_agent_ids = max_assignment_limit.present? ? get_agent_ids_over_assignment_limit(max_assignment_limit) : []
    super - overloaded_agent_ids
  end

  def active_bot?
    super || captain_active?
  end

  # Goodmarket: Chatwoot's own per-account monthly cap (`more_responses?`
  # below) never bites on a self-hosted install — `increment_response_usage`
  # is a no-op unless `ChatwootApp.chatwoot_cloud?`, so `current_available`
  # sits at `ChatwootApp.max_limit` (100,000) forever. Without a cap of our
  # own, a single visitor spamming ONE conversation has no ceiling at all —
  # one OpenAI call per message, unbounded. `conversation` is optional so
  # `active_bot?` below (which has no specific conversation in view) keeps
  # its old behavior.
  CAPTAIN_MAX_RESPONSES_PER_CONVERSATION = 20

  def captain_active?(conversation = nil)
    captain_assistant.present? && more_responses? && within_conversation_captain_limit?(conversation)
  end

  private

  def within_conversation_captain_limit?(conversation)
    return true if conversation.blank?

    conversation.messages.outgoing.where(sender_type: 'Captain::Assistant').count < CAPTAIN_MAX_RESPONSES_PER_CONVERSATION
  end

  def more_responses?
    account.usage_limits[:captain][:responses][:current_available].positive?
  end

  def get_agent_ids_over_assignment_limit(limit)
    conversations
      .open
      .where(account_id: account_id)
      .select(:assignee_id)
      .group(:assignee_id)
      .having("count(*) >= #{limit.to_i}")
      .filter_map(&:assignee_id)
  end

  def ensure_valid_max_assignment_limit
    return if auto_assignment_config['max_assignment_limit'].blank?
    return if auto_assignment_config['max_assignment_limit'].to_i.positive?

    errors.add(:auto_assignment_config, 'max_assignment_limit must be greater than 0')
  end
end
