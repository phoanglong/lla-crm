# frozen_string_literal: true

# Trợ lý AI của một tài khoản (LLA AI — thay Captain EE, ADR-OMCRM-033).
#
# Hợp đồng lấy từ nguồn MIT: db/schema.rb (bảng captain_assistants),
# spec/enterprise/models/captain/assistant_spec.rb (đã chuyển sang spec/lla) và
# UI Vue app/javascript/dashboard (module captain).
class Captain::Assistant < ApplicationRecord
  self.table_name = 'captain_assistants'

  CUSTOM_HTTP_TOOLS_FLAG = 'LLA_AI_CUSTOM_HTTP_TOOLS_ENABLED'

  include Concerns::Agentable
  include Avatarable

  belongs_to :account

  has_many :documents, class_name: 'Captain::Document', dependent: :destroy_async, inverse_of: :assistant
  has_many :responses, class_name: 'Captain::AssistantResponse', dependent: :destroy_async, inverse_of: :assistant
  has_many :captain_inboxes, class_name: 'CaptainInbox', foreign_key: :captain_assistant_id,
                             dependent: :destroy_async, inverse_of: :captain_assistant
  has_many :inboxes, through: :captain_inboxes
  has_many :messages, as: :sender, dependent: :nullify
  has_many :scenarios, class_name: 'Captain::Scenario', dependent: :destroy_async, inverse_of: :assistant
  has_many :agent_sessions, class_name: 'Captain::AgentSession', dependent: :destroy_async, inverse_of: :assistant
  has_many :faq_suggestions, class_name: 'Captain::FaqSuggestion', dependent: :destroy_async, inverse_of: :assistant

  # Cờ tính năng + tham số sinh của trợ lý nằm trong config jsonb (UI chỉnh).
  store_accessor :config, :feature_faq, :feature_memory, :feature_contact_attributes, :temperature

  scope :ordered, -> { order(created_at: :desc) }
  scope :for_account, ->(account_id) { where(account_id: account_id) }

  validates :name, presence: true
  validates :description, presence: true

  # Outbound HTTP from assistant tools: read strictly, so a misspelt value cannot
  # switch it on. See `ChatwootApp.enabled_flag?`.
  def self.custom_http_tools_enabled?
    ChatwootApp.enabled_flag?(CUSTOM_HTTP_TOOLS_FLAG)
  end

  def self.custom_http_tools_enabled_for?(account)
    custom_http_tools_enabled? && account.feature_enabled?('custom_tools')
  end

  def available_name
    name
  end

  # Danh mục công cụ khả dụng của trợ lý (metadata cho UI/scenario): built-in +
  # công cụ HTTP tuỳ chỉnh đang bật của account.
  def available_agent_tools
    tools = Concerns::CaptainToolsHelpers::BUILT_IN_AGENT_TOOLS.dup
    return tools unless custom_http_tools_enabled?

    tools + account.captain_custom_tools.enabled.map(&:to_tool_metadata)
  end

  def available_tool_ids
    available_agent_tools.pluck(:id)
  end

  def push_event_data
    {
      id: id,
      name: name,
      avatar_url: avatar_url,
      type: 'captain_assistant'
    }
  end

  def webhook_data
    {
      id: id,
      name: name,
      type: 'captain_assistant'
    }
  end

  private

  def agent_name
    name
  end

  def prompt_context
    context = {
      name: name,
      description: description,
      config: config,
      response_guidelines: response_guidelines,
      guardrails: guardrails
    }
    context[:scenarios] = scenarios_prompt_context
    context
  end

  # Scenario đang bật của trợ lý, kèm handoff key để prompt điều hướng.
  def scenarios_prompt_context
    scenarios.where(enabled: true).map do |scenario|
      {
        id: scenario.id,
        title: scenario.title,
        instruction: scenario.instruction,
        key: scenario.handoff_key
      }
    end
  end

  # Bộ công cụ của trợ lý: tra cứu FAQ + chuyển người thật luôn có mặt; công cụ
  # HTTP tuỳ chỉnh lấy theo tài khoản, chỉ những cái đang bật.
  def agent_tools
    tools = [
      Captain::Tools::FaqLookupTool.new(self),
      Captain::Tools::HandoffTool.new(self)
    ]

    if custom_http_tools_enabled?
      account.captain_custom_tools.enabled.find_each do |custom_tool|
        tools << Captain::Tools::HttpTool.new(self, custom_tool)
      end
    end

    tools
  end

  def custom_http_tools_enabled?
    self.class.custom_http_tools_enabled_for?(account)
  end
end
