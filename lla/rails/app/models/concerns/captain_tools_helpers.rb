# frozen_string_literal: true

# Nhận diện tham chiếu công cụ dạng [@Tên](tool://tool_id) trong văn bản
# (hướng dẫn của trợ lý/scenario) và phân giải về lớp công cụ tương ứng.
module Concerns::CaptainToolsHelpers
  extend ActiveSupport::Concern

  TOOL_REFERENCE_REGEX = %r{\[[^\]]+\]\(tool://([a-z0-9_-]+)\)}

  # Bộ công cụ built-in chèn được vào hướng dẫn scenario qua [Tên](tool://id).
  BUILT_IN_AGENT_TOOLS = [
    { id: 'add_contact_note', title: 'Add Contact Note', description: 'Add a note to a contact profile' },
    { id: 'add_label_to_conversation', title: 'Add Label to Conversation', description: 'Add a label to a conversation' },
    { id: 'add_private_note', title: 'Add Private Note', description: 'Add a private note to a conversation' },
    { id: 'faq_lookup', title: 'FAQ Lookup', description: 'Search FAQ responses using semantic similarity to find relevant answers' },
    { id: 'handoff', title: 'Handoff to Human', description: 'Hand off the conversation to a human agent when unable to assist further' },
    { id: 'resolve_conversation', title: 'Resolve Conversation', description: 'Resolve the conversation when the issue is handled' },
    { id: 'update_priority', title: 'Update Priority', description: 'Update the priority of a conversation' }
  ].freeze

  BUILT_IN_TOOL_IDS = BUILT_IN_AGENT_TOOLS.pluck(:id).freeze

  class_methods do
    def built_in_tool_ids
      BUILT_IN_TOOL_IDS
    end

    def built_in_agent_tools
      BUILT_IN_AGENT_TOOLS
    end

    def resolve_tool_class(tool_id)
      "Captain::Tools::#{tool_id.camelize}Tool".constantize
    rescue NameError
      nil
    end
  end

  def extract_tool_ids_from_text(text)
    return [] if text.blank?

    text.scan(TOOL_REFERENCE_REGEX).flatten.uniq
  end
end
