# frozen_string_literal: true

class Captain::Llm::WebsiteAnalysisSchema < RubyLLM::Schema
  string :business_name, description: 'Business or brand name.', max_length: 120
  string :suggested_assistant_name, description: 'Friendly support assistant name.', max_length: 80
  string :description, description: 'General support assistant persona.', max_length: 500
end
