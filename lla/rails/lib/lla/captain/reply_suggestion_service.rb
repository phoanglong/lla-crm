# frozen_string_literal: true

# LLA-owned reply suggestions enforce the caller's current conversation access
# before formatting any messages or invoking a provider. Documentation search is
# available by capability and is always bound to the inbox's account assistant.
module Lla::Captain::ReplySuggestionService
  def perform
    return inaccessible_conversation_result unless authorized_conversation?

    super
  end

  def make_api_call(messages:, model: nil, feature: nil, schema: nil, tools: [])
    return super unless use_search_tool?

    @lla_forwarding_search_tool = true
    super(
      messages: messages,
      model: model,
      feature: feature,
      schema: schema,
      tools: tools_without_search_tool(tools) + [build_search_tool]
    )
  ensure
    @lla_forwarding_search_tool = false
  end

  private

  def authorized_conversation?
    return false unless user && AccountUser.exists?(account_id: account.id, user_id: user.id)
    return false unless conversation

    Conversations::PermissionFilterService
      .new(account.conversations, user, account)
      .perform
      .exists?(id: conversation.id)
  end

  def inaccessible_conversation_result
    { error: 'Conversation is unavailable', error_code: 404 }
  end

  def use_search_tool?
    return false if @lla_forwarding_search_tool

    account.feature_enabled?('captain_tasks') && search_assistant.present?
  end

  def prompt_variables
    variables = super
    use_search_tool? ? variables.merge('has_search_tool' => true) : variables
  end

  def build_search_tool
    Captain::Tools::SearchReplyDocumentationService.new(account: account, assistant: search_assistant)
  end

  def search_assistant
    candidate = conversation&.inbox&.captain_assistant
    @search_assistant = candidate if candidate&.account_id == account.id
  end

  def tools_without_search_tool(tools)
    tools.reject { |tool| tool.is_a?(Captain::Tools::SearchReplyDocumentationService) }
  end
end
