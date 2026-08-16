# frozen_string_literal: true

class Captain::Scenario < ApplicationRecord
  DESCRIPTION_LENGTH_LIMIT = 500
  TITLE_LENGTH_LIMIT = 160
  INSTRUCTION_LENGTH_LIMIT = 12_000
  TOOL_COUNT_LIMIT = 20

  include Concerns::CaptainToolsHelpers
  include Concerns::Agentable

  HANDOFF_TOOL_PREFIX = 'handoff_to_'
  HANDOFF_KEY_PREFIX = 'scenario'
  HANDOFF_KEY_SUFFIX = 'agent'
  MAX_HANDOFF_TOOL_NAME_LENGTH = 60
  MAX_AGENT_NAME_LENGTH = MAX_HANDOFF_TOOL_NAME_LENGTH - HANDOFF_TOOL_PREFIX.length
  MAX_HANDOFF_SLUG_LENGTH = 24

  self.table_name = 'captain_scenarios'

  belongs_to :assistant, class_name: 'Captain::Assistant', inverse_of: :scenarios
  belongs_to :account

  validates :title, presence: true, length: { maximum: TITLE_LENGTH_LIMIT }
  validates :description, presence: true, length: { maximum: DESCRIPTION_LENGTH_LIMIT }
  validates :instruction, presence: true, length: { maximum: INSTRUCTION_LENGTH_LIMIT }
  validates :assistant_id, presence: true
  validates :account_id, presence: true
  validate :validate_instruction_tools
  validate :validate_tool_count

  scope :enabled, -> { where(enabled: true) }

  delegate :temperature, :feature_faq, :feature_memory, :product_name, :response_guidelines, :guardrails, to: :assistant

  before_validation :ensure_account
  before_save :resolve_tool_references

  def handoff_key
    [handoff_id_key, compact_handoff_slug, HANDOFF_KEY_SUFFIX].compact.join('_')
  end

  def prompt_context
    {
      title: title,
      instructions: resolved_instructions,
      tools: resolved_tools,
      assistant_name: assistant.name.downcase.gsub(/\s+/, '_'),
      response_guidelines: response_guidelines || [],
      guardrails: guardrails || []
    }
  end

  private

  def ensure_account
    self.account_id = assistant&.account_id
  end

  def agent_name
    handoff_key
  end

  def handoff_id_key
    return "#{HANDOFF_KEY_PREFIX}_#{id}" if id.present?

    "#{HANDOFF_KEY_PREFIX}_draft"
  end

  def compact_handoff_slug
    slug = title.to_s.parameterize(separator: '_').presence
    return nil if slug.blank?

    max_slug_length = [MAX_HANDOFF_SLUG_LENGTH, dynamic_slug_max_length].min
    return nil if max_slug_length <= 0

    slug.first(max_slug_length).sub(/_+\z/, '').presence
  end

  def dynamic_slug_max_length
    MAX_AGENT_NAME_LENGTH - handoff_id_key.length - HANDOFF_KEY_SUFFIX.length - 2
  end

  def agent_tools
    resolved_tools.filter_map { |tool| resolve_tool_instance(tool) }
  end

  def resolved_instructions
    instruction.gsub(TOOL_REFERENCE_REGEX, '`\1` tool')
  end

  def resolved_tools
    return [] if tools.blank?

    available_tools = assistant.available_agent_tools
    tools.filter_map { |tool_id| available_tools.find { |tool| tool[:id] == tool_id } }
  end

  def resolve_tool_instance(tool_metadata)
    tool_id = tool_metadata[:id]

    if tool_metadata[:custom]
      custom_tool = account.captain_custom_tools.enabled.find_by(slug: tool_id)
      custom_tool&.tool(assistant)
    else
      self.class.resolve_tool_class(tool_id)&.new(assistant)
    end
  end

  def validate_instruction_tools
    return if instruction.blank? || assistant.blank?

    invalid_tools = extract_tool_ids_from_text(instruction) - assistant.available_tool_ids
    errors.add(:instruction, "contains invalid tools: #{invalid_tools.join(', ')}") if invalid_tools.any?
  end

  def validate_tool_count
    return if tools.blank? || (tools.is_a?(Array) && tools.length <= TOOL_COUNT_LIMIT)

    errors.add(:tools, "cannot contain more than #{TOOL_COUNT_LIMIT} entries")
  end

  def resolve_tool_references
    return if instruction.blank?

    self.tools = extract_tool_ids_from_text(instruction).first(TOOL_COUNT_LIMIT).presence
  end
end
