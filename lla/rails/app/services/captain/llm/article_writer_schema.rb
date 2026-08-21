# frozen_string_literal: true

class Captain::Llm::ArticleWriterSchema < RubyLLM::Schema
  string :title, description: 'Concise plain-text article title.', max_length: 80
  string :description, description: 'One-sentence article summary.', max_length: 200
  string :content, description: 'Evidence-based Help Center article in safe Markdown.', max_length: 18_000
end
