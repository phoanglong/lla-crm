# frozen_string_literal: true

class Captain::Llm::ContactAttributesService < Lla::Llm::BackgroundService
  MAX_ATTRIBUTES = 20
  MAX_TEXT_BYTES = 1_000
  NORMALIZERS = {
    'text' => :bounded_string,
    'link' => :valid_link,
    'number' => :finite_number,
    'currency' => :finite_number,
    'percent' => :finite_number,
    'date' => :iso_date,
    'list' => :list_value,
    'checkbox' => :boolean
  }.freeze

  def initialize(assistant, conversation)
    super()
    @assistant_id = assistant&.id
    @conversation_id = conversation&.id
    @account_id = conversation&.account_id
  end

  def generate_and_update_attributes
    return {} unless assign_runtime_context

    definitions = allowed_definitions
    return {} if definitions.empty?

    updates = normalize_attributes(generate_attributes(definitions), definitions.index_by(&:attribute_key))
    persist_attributes(updates)
  rescue RubyLLM::Error => e
    capture_failure(e, 'contact_attributes')
    {}
  end

  private

  def assign_runtime_context
    assign_memory_runtime_context(
      assistant_id: @assistant_id, conversation_id: @conversation_id, account_id: @account_id
    )
  end

  def allowed_definitions
    account.custom_attribute_definitions.contact_attribute.order(:id).limit(MAX_ATTRIBUTES)
  end

  def generate_attributes(definitions)
    request_json(
      system_prompt: Captain::Llm::SystemPromptsService.attributes_generator(definitions),
      content: memory_context,
      span_name: 'llm.captain.contact_attributes',
      metadata: {
        feature_name: 'contact_attributes', assistant_id: assistant.id, contact_id: contact.id,
        definition_count: definitions.size
      }
    ).fetch('attributes', [])
  end

  def normalize_attributes(value, definitions)
    return {} unless value.is_a?(Array)

    value.first(MAX_ATTRIBUTES).each_with_object({}) do |candidate, result|
      next unless candidate.is_a?(Hash)

      data = candidate.stringify_keys
      definition = definitions[data['key'].to_s]
      normalized = normalize_value(definition, data['value']) if definition
      result[definition.attribute_key] = normalized unless normalized.nil?
    end
  end

  def normalize_value(definition, value)
    normalizer = NORMALIZERS[definition.attribute_display_type]
    send(normalizer, value, definition) if normalizer
  end

  def bounded_string(value, _definition = nil)
    return unless value.is_a?(String)

    truncate_bytes(value.unicode_normalize(:nfc).squish, MAX_TEXT_BYTES).presence
  end

  def valid_link(value, _definition = nil)
    string = bounded_string(value)
    uri = URI.parse(string.to_s)
    string if uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end

  def finite_number(value, _definition = nil)
    number = value.is_a?(Numeric) ? value : Float(value, exception: false)
    number if number&.finite?
  end

  def iso_date(value, _definition = nil)
    string = value.to_s
    Date.iso8601(string).iso8601 if string.match?(/\A\d{4}-\d{2}-\d{2}\z/)
  rescue Date::Error
    nil
  end

  def list_value(value, definition)
    value if definition.attribute_values.to_a.include?(value)
  end

  def boolean(value, _definition = nil)
    return value if value == true || value == false

    nil
  end

  def persist_attributes(updates)
    return {} if updates.empty?

    contact.with_lock do
      contact.reload
      next unless contact.account_id == account.id

      contact.update!(custom_attributes: contact.custom_attributes.to_h.merge(updates))
    end
    audit_persistence(updates.keys)
    updates
  end

  def audit_persistence(keys)
    Rails.logger.info(
      "LLA Captain contact memory persisted kind=attributes account_id=#{account.id} " \
      "contact_id=#{contact.id} conversation_id=#{conversation.id} keys=#{keys.sort.join(',')}"
    )
  end
end
