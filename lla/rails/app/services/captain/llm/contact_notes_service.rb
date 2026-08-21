# frozen_string_literal: true

class Captain::Llm::ContactNotesService < Lla::Llm::BackgroundService
  MAX_NOTES = 8
  MAX_NOTE_BYTES = 1_000

  def initialize(assistant, conversation)
    super()
    @assistant_id = assistant&.id
    @conversation_id = conversation&.id
    @account_id = conversation&.account_id
  end

  def generate_and_update_notes
    return [] unless assign_runtime_context

    notes = normalize_notes(generate_notes)
    persist_notes(notes)
  rescue RubyLLM::Error => e
    capture_failure(e, 'contact_notes')
    []
  end

  private

  def assign_runtime_context
    assign_memory_runtime_context(
      assistant_id: @assistant_id, conversation_id: @conversation_id, account_id: @account_id
    )
  end

  def generate_notes
    request_json(
      system_prompt: Captain::Llm::SystemPromptsService.notes_generator(account.locale_english_name),
      content: memory_context(include_notes: true),
      span_name: 'llm.captain.contact_notes',
      metadata: {
        feature_name: 'contact_notes', assistant_id: assistant.id, contact_id: contact.id
      }
    ).fetch('notes', [])
  end

  def normalize_notes(value)
    return [] unless value.is_a?(Array)

    value.first(MAX_NOTES).filter_map do |note|
      next unless note.is_a?(String)

      normalized = truncate_bytes(note.unicode_normalize(:nfc).squish, MAX_NOTE_BYTES)
      normalized.presence
    end.uniq
  end

  def persist_notes(notes)
    created = []
    contact.with_lock do
      contact.reload
      next unless contact.account_id == account.id

      notes.each do |content|
        next if contact.notes.exists?(account_id: account.id, content: content)

        created << contact.notes.create!(account: account, content: content)
      end
    end
    audit_persistence('notes', created.size)
    created
  end

  def audit_persistence(kind, count)
    Rails.logger.info(
      "LLA Captain contact memory persisted kind=#{kind} account_id=#{account.id} " \
      "contact_id=#{contact.id} conversation_id=#{conversation.id} count=#{count}"
    )
  end
end
