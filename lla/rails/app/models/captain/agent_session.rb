# frozen_string_literal: true

class Captain::AgentSession < ApplicationRecord
  self.table_name = 'agent_sessions'

  SUBJECT_TYPES = { 'assistant' => 'Conversation', 'copilot' => 'CopilotThread' }.freeze
  RESULT_TYPES = { 'assistant' => 'Message', 'copilot' => 'CopilotMessage' }.freeze
  MAX_REFERENCE_IDS = 100
  MAX_RUN_CONTEXT_BYTES = 65_536

  belongs_to :account
  belongs_to :assistant, class_name: 'Captain::Assistant', inverse_of: :agent_sessions
  belongs_to :user, optional: true
  belongs_to :subject, ->(session) { where(account_id: session.account_id) }, polymorphic: true
  belongs_to :result, ->(session) { where(account_id: session.account_id) }, polymorphic: true, optional: true

  enum :session_type, { assistant: 0, copilot: 1 }, prefix: :session

  before_validation :ensure_account

  validates :user, presence: true, if: :session_copilot?
  validate :subject_type_matches_session_type
  validate :result_type_matches_session_type, if: -> { result_type.present? }
  validate :subject_belongs_to_account
  validate :result_belongs_to_account, if: -> { result_id.present? }
  validate :user_belongs_to_account, if: -> { user_id.present? }
  validate :copilot_context_is_consistent, if: :session_copilot?
  validate :result_matches_subject, if: -> { result_id.present? && subject_id.present? }
  validate :bounded_reference_data

  private

  def ensure_account
    self.account_id = assistant&.account_id
  end

  def subject_type_matches_session_type
    expected_type = SUBJECT_TYPES[session_type]
    return if subject_type == expected_type

    errors.add(:subject_type, "must be #{expected_type} for #{session_type} sessions")
  end

  def result_type_matches_session_type
    expected_type = RESULT_TYPES[session_type]
    return if result_type == expected_type

    errors.add(:result_type, "must be #{expected_type} for #{session_type} sessions")
  end

  def subject_belongs_to_account
    return if subject.nil? || subject.account_id == account_id

    errors.add(:subject, 'must belong to the session account')
  end

  def result_belongs_to_account
    target_class = result_type.safe_constantize
    actual_account_id = target_class&.unscoped&.where(id: result_id)&.pick(:account_id)
    return if actual_account_id == account_id

    errors.add(:result, 'must belong to the session account')
  end

  def user_belongs_to_account
    return if AccountUser.exists?(account_id: account_id, user_id: user_id)

    errors.add(:user, 'must belong to the session account')
  end

  def copilot_context_is_consistent
    return unless subject.is_a?(CopilotThread)
    return if subject.assistant_id == assistant_id && subject.user_id == user_id

    errors.add(:subject, 'must use the session assistant and user')
  end

  def result_matches_subject
    return if assistant_result_matches_subject? || copilot_result_matches_subject?

    errors.add(:result, 'must belong to the session subject')
  end

  def bounded_reference_data
    %i[faq_ids document_ids scenario_ids].each do |attribute|
      errors.add(attribute, 'must be a bounded list of positive IDs') unless valid_reference_ids?(public_send(attribute))
    end

    errors.add(:run_context, 'is too large or invalid') unless valid_run_context?
  end

  def assistant_result_matches_subject?
    session_assistant? && result_type == 'Message' && result&.conversation_id == subject_id
  end

  def copilot_result_matches_subject?
    session_copilot? && result_type == 'CopilotMessage' && result&.copilot_thread_id == subject_id
  end

  def valid_reference_ids?(values)
    values.is_a?(Array) && values.length <= MAX_REFERENCE_IDS && values.all? { |id| id.is_a?(Integer) && id.positive? }
  end

  def valid_run_context?
    run_context.is_a?(Hash) && run_context.to_json.bytesize <= MAX_RUN_CONTEXT_BYTES
  end
end
