# frozen_string_literal: true

class CaptainListener < BaseListener
  include ::Events::Types

  def conversation_resolved(event)
    conversation = extract_conversation_and_account(event)[0]
    assistant = same_account_assistant(conversation)
    return if assistant.blank? || !conversation.inbox.captain_active?

    generate_contact_memory(assistant, conversation) if enabled?(assistant, 'feature_memory')
    enqueue_faq_generation(assistant, conversation) if enabled?(assistant, 'feature_faq')
  end

  private

  def same_account_assistant(conversation)
    assistant = conversation.inbox.captain_assistant
    assistant if assistant&.account_id == conversation.account_id
  end

  def enabled?(assistant, feature)
    ActiveModel::Type::Boolean.new.cast(assistant.config[feature])
  end

  def generate_contact_memory(assistant, conversation)
    invoke_memory_service(
      'Captain::Llm::ContactAttributesService', :generate_and_update_attributes, assistant, conversation
    )
    invoke_memory_service('Captain::Llm::ContactNotesService', :generate_and_update_notes, assistant, conversation)
  end

  def invoke_memory_service(class_name, method_name, assistant, conversation)
    service_class = class_name.safe_constantize
    return log_deferred_feature(class_name.demodulize.underscore, conversation) unless service_class

    service_class.new(assistant, conversation).public_send(method_name)
  end

  def enqueue_faq_generation(assistant, conversation)
    job_class = 'Captain::Llm::ConversationFaqJob'.safe_constantize
    return log_deferred_feature('conversation_faq', conversation) unless job_class

    job_class.perform_later(conversation, assistant)
  end

  def log_deferred_feature(feature, conversation)
    Rails.logger.info(
      "LLA Captain resolved-conversation feature deferred feature=#{feature} " \
      "account_id=#{conversation.account_id} conversation_id=#{conversation.id}"
    )
  end
end
