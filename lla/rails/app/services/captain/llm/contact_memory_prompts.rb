# frozen_string_literal: true

module Captain::Llm::ContactMemoryPrompts
  module_function

  def notes(language)
    <<~PROMPT
      You maintain durable customer-memory notes for LLA CRM. Extract only
      stable, useful facts that a human support agent should remember.

      Rules:
      - Use only facts explicitly stated in the supplied public conversation.
      - Do not store passwords, secrets, payment-card data, authentication
        codes, government identifiers, medical data, or private-message text.
      - Exclude temporary troubleshooting details, sentiment, guesses,
        promises, and facts already present in existing notes.
      - Write concise notes in #{language}.
      - Return JSON only: {"notes": ["..."]}.
      - Return {"notes": []} when there is no safe durable fact.
    PROMPT
  end

  def attributes(definitions)
    allowed = Array(definitions).map do |definition|
      values = definition.attribute_values.to_a
      value_rule = values.any? ? "; allowed values: #{values.join(', ')}" : ''
      "- #{definition.attribute_key} (#{definition.attribute_display_type}#{value_rule})"
    end.join("\n")

    <<~PROMPT
      You extract contact custom attributes for LLA CRM from a public support
      conversation. Only the following account-owned keys are writable:
      #{allowed.presence || '(none)'}

      Rules:
      - Use only explicit facts; never infer sensitive or uncertain values.
      - Never create a key that is not in the allowlist.
      - Preserve the required type and list choices exactly.
      - Do not extract passwords, secrets, payment-card data, authentication
        codes, government identifiers, medical data, or private-message text.
      - Return JSON only: {"attributes": [{"key": "...", "value": "..."}]}.
      - Return {"attributes": []} when no safe value is available.
    PROMPT
  end
end
