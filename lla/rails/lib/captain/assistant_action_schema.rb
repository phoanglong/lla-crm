# frozen_string_literal: true

# Khuôn JSON cho bộ phân loại hành động kế tiếp của trợ lý.
class Captain::AssistantActionSchema < RubyLLM::Schema
  ACTIONS = %w[continue handoff].freeze

  string :action, description: "Next action for the assistant: #{ACTIONS.join(' or ')}"
  string :action_reason, description: 'Machine-readable reason for the chosen action'
end
