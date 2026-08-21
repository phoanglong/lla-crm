# frozen_string_literal: true

# Biến một model/service thành "agent" chạy trên gem ai-agents: dựng
# Agents::Agent với prompt render từ template liquid, model chọn theo tài khoản,
# và bộ công cụ do lớp include tự khai.
#
# Lớp include phải cài `agent_name` và `prompt_context`; có thể override
# `agent_tools`, `temperature`, `account`.
module Concerns::Agentable
  DEFAULT_TEMPERATURE = 0.5

  def agent
    Agents::Agent.new(
      name: agent_name,
      instructions: ->(context) { agent_instructions(context) },
      tools: agent_tools,
      model: agent_model,
      temperature: agent_temperature,
      response_schema: agent_response_schema
    )
  end

  def agent_instructions(run_context = nil)
    Captain::PromptRenderer.render(template_name, prompt_context.merge(run_state_context(run_context)))
  end

  # Thứ tự chọn model: account override → cờ captain_integration_v2 →
  # InstallationConfig CAPTAIN_OPEN_AI_MODEL → mặc định theo feature.
  # Public: lớp ghi phiên chạy (session capture) đọc model của trợ lý.
  def agent_model
    agent_account = try(:account)
    override = account_model_override(agent_account)
    return override if override
    return Llm::FeatureRouter::CAPTAIN_V2_ASSISTANT_MODEL if agent_account&.feature_enabled?('captain_integration_v2')

    InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence ||
      Llm::Models.default_model_for('assistant')
  end

  def account_model_override(agent_account)
    override = agent_account&.captain_models&.[]('assistant').presence
    override if override && Llm::Models.valid_model_for?('assistant', override)
  end

  private

  def agent_name
    raise NotImplementedError, "#{self.class.name} must implement agent_name"
  end

  def prompt_context
    raise NotImplementedError, "#{self.class.name} must implement prompt_context"
  end

  def agent_tools
    []
  end

  def agent_temperature
    value = try(:temperature)
    value.present? ? value.to_f : DEFAULT_TEMPERATURE
  end

  def agent_response_schema
    Captain::ResponseSchema
  end

  def template_name
    self.class.name.demodulize.underscore
  end

  # Trộn trạng thái phiên chạy (hội thoại/contact/campaign) vào ngữ cảnh prompt.
  def run_state_context(run_context)
    return {} if run_context.blank?

    state = run_context.context[:state] || {}
    {
      conversation: state[:conversation] || {},
      contact: state[:contact],
      campaign: state[:campaign] || {}
    }
  end
end
