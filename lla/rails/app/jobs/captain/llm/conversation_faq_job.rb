# frozen_string_literal: true

require 'digest'
require 'securerandom'

class Captain::Llm::ConversationFaqJob < ApplicationJob
  queue_as :low

  CLAIM_TTL = 15.minutes.to_i
  CLAIM_KEY = 'LLA_CAPTAIN_CONVERSATION_FAQ::%<account_id>d::%<assistant_id>d::%<conversation_id>d::%<revision>s'

  retry_on ActiveRecord::Deadlocked, ActiveJob::EnqueueError, wait: :polynomially_longer, attempts: 5

  def perform(conversation, assistant)
    assign_runtime_context(conversation, assistant)
    return unless valid_runtime_context?

    key = claim_key
    token = SecureRandom.hex(16)
    return unless Redis::Alfred.set(key, token, nx: true, ex: CLAIM_TTL)

    Captain::Llm::ConversationFaqService.new(@assistant, @conversation).generate_suggestions
  ensure
    Redis::Alfred.delete_if_equals(key, token) if key && token
  end

  private

  def assign_runtime_context(conversation, assistant)
    @conversation = Conversation.includes(inbox: :captain_assistant).find_by(id: conversation&.id)
    @assistant = Captain::Assistant.find_by(id: assistant&.id)
  end

  def valid_runtime_context?
    return false unless @conversation && @assistant

    [
      @conversation.resolved?,
      @conversation.account.active?,
      ActiveModel::Type::Boolean.new.cast(@assistant.config['feature_faq']),
      @assistant.account_id == @conversation.account_id,
      @conversation.inbox.account_id == @conversation.account_id,
      @conversation.inbox.captain_assistant == @assistant
    ].all?
  end

  def claim_key
    format(
      CLAIM_KEY,
      account_id: @conversation.account_id,
      assistant_id: @assistant.id,
      conversation_id: @conversation.id,
      revision: revision
    )
  end

  def revision
    Digest::SHA256.hexdigest(
      [@conversation.status, @conversation.last_activity_at&.to_f, @conversation.updated_at&.to_f].join(':')
    ).first(24)
  end
end
