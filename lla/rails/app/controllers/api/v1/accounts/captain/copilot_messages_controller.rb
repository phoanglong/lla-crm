# frozen_string_literal: true

class Api::V1::Accounts::Captain::CopilotMessagesController < Api::V1::Accounts::BaseController
  MESSAGES_PER_PAGE = 100

  before_action :set_copilot_thread
  before_action :ensure_message, only: :create

  def index
    @copilot_messages = @copilot_thread.copilot_messages
                                       .includes(:copilot_thread)
                                       .order(created_at: :asc, id: :asc)
                                       .page(permitted_params[:page] || 1)
                                       .per(MESSAGES_PER_PAGE)
  end

  def create
    @copilot_message = @copilot_thread.copilot_messages.create!(
      message: { content: message_content },
      message_type: :user,
      conversation: authorized_conversation
    )
    @copilot_message.schedule_response!
  end

  private

  def set_copilot_thread
    @copilot_thread = Current.account.copilot_threads.find_by!(id: params[:copilot_thread_id], user: Current.user)
  end

  def ensure_message
    return if params[:message].is_a?(String) && params[:message].strip.present?

    render_could_not_create_error(I18n.t('captain.copilot_message_required'))
  end

  def message_content
    @message_content ||= params[:message].to_s.strip
  end

  def authorized_conversation
    return if params[:conversation_id].blank?

    display_id = Integer(params[:conversation_id], exception: false)
    raise ActiveRecord::RecordNotFound unless display_id&.positive?

    permissible_conversations.find_by!(display_id: display_id)
  end

  def permissible_conversations
    Conversations::PermissionFilterService.new(Current.account.conversations, Current.user, Current.account).perform
  end

  def permitted_params
    params.permit(:page)
  end
end
