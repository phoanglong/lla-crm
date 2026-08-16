# frozen_string_literal: true

# Adapter cho pipeline RubyLLM V1; toàn bộ HTTP execution vẫn đi qua HttpTool
# để V1/V2 dùng chung SSRF, redirect, timeout, credential và output policy.
class Captain::Tools::CustomHttpTool < Captain::Tools::BaseTool
  prepend Captain::Tools::Instrumentation

  attr_reader :custom_tool

  def initialize(assistant, custom_tool, conversation: nil)
    @custom_tool = custom_tool
    @conversation = conversation
    super(assistant)
  end

  def active?
    valid_records? && custom_tools_enabled? && valid_conversation?
  end

  def execute(**params)
    return 'An error occurred while executing the request' unless active?

    Captain::Tools::HttpTool.new(assistant, custom_tool).perform(build_tool_context, **params)
  end

  private

  def valid_records?
    assistant&.persisted? && custom_tool.persisted? && custom_tool.enabled? && custom_tool.valid? &&
      custom_tool.account_id == assistant.account_id
  end

  def custom_tools_enabled?
    account = Account.find_by(id: assistant.account_id)
    account.present? && Captain::Assistant.custom_http_tools_enabled_for?(account)
  end

  def valid_conversation?
    return true if @conversation.nil?

    @conversation.persisted? && @conversation.account_id == assistant.account_id &&
      @conversation.inbox&.account_id == assistant.account_id &&
      CaptainInbox.exists?(inbox_id: @conversation.inbox_id, captain_assistant_id: assistant.id)
  end

  def build_tool_context
    state = { account_id: assistant.account_id, assistant_id: assistant.id }
    add_conversation_state(state) if @conversation
    OpenStruct.new(state: state)
  end

  def add_conversation_state(state)
    state[:conversation] = { id: @conversation.id, display_id: @conversation.display_id }
    state[:contact] = slice_record_attrs(@conversation.contact, :id)
    state[:contact_inbox] = slice_record_attrs(@conversation.contact_inbox, :id, :hmac_verified)
  end

  def slice_record_attrs(record, *keys)
    record&.attributes&.symbolize_keys&.slice(*keys)
  end
end
