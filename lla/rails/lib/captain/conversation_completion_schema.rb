# frozen_string_literal: true

class Captain::ConversationCompletionSchema < RubyLLM::Schema
  boolean :complete, description: 'Whether the support conversation can be closed safely'
  string :reason, description: 'A short explanation for the completion decision'
end
