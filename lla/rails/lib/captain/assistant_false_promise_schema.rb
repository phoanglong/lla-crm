# frozen_string_literal: true

# Khuôn JSON cho bộ soát lời hứa ngoài ngữ cảnh trong câu trả lời dự kiến.
class Captain::AssistantFalsePromiseSchema < RubyLLM::Schema
  string :decision, description: 'safe or unsafe'
  string :reason, description: 'Machine-readable reason for the decision'
end
