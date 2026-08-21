# frozen_string_literal: true

class Captain::Llm::HelpCenterCurationSchema < RubyLLM::Schema
  array :categories, description: 'One to ten reusable Help Center categories.', min_items: 1, max_items: 10 do
    object do
      string :name, description: 'Short category name.', max_length: 60
      string :description, description: 'One-sentence category description.', max_length: 200
    end
  end

  array :articles, description: 'One to twenty-five useful draft article plans.', min_items: 1, max_items: 25 do
    object do
      array :urls, description: 'One to three exact URLs from the input.', min_items: 1, max_items: 3, of: :string
      string :title, description: 'Concise plain-text title.', max_length: 80
      string :category_name, description: 'Exact emitted category name.', max_length: 60
    end
  end
end
