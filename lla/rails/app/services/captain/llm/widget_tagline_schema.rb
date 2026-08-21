# frozen_string_literal: true

class Captain::Llm::WidgetTaglineSchema < RubyLLM::Schema
  string :tagline,
         description: 'Short customer-support widget tagline. Plain text, no quotes, emoji, or trailing punctuation.',
         max_length: 60
end
