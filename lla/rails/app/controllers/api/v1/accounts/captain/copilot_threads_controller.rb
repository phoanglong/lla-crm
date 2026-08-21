# frozen_string_literal: true

class Api::V1::Accounts::Captain::CopilotThreadsController < Api::V1::Accounts::BaseController
  THREADS_PER_PAGE = 5

  before_action :ensure_message, only: :create

  def index
    @copilot_threads = Current.account.copilot_threads
                              .where(user_id: Current.user.id)
                              .includes(:user, :assistant)
                              .order(created_at: :desc, id: :desc)
                              .page(permitted_params[:page] || 1)
                              .per(THREADS_PER_PAGE)
  end

  def create
    source_message = ActiveRecord::Base.transaction do
      @copilot_thread = Current.account.copilot_threads.create!(
        title: bounded_title(message_content),
        user: Current.user,
        assistant: assistant
      )
      @copilot_thread.copilot_messages.create!(
        message_type: :user,
        message: { content: message_content },
        conversation: authorized_conversation
      )
    end
    source_message.schedule_response!
  end

  private

  def ensure_message
    return if params[:message].is_a?(String) && params[:message].strip.present?

    render_could_not_create_error(I18n.t('captain.copilot_message_required'))
  end

  def message_content
    @message_content ||= params[:message].to_s.strip
  end

  def bounded_title(content)
    content.byteslice(0, CopilotThread::TITLE_LENGTH_LIMIT).to_s.scrub
  end

  def assistant
    @assistant ||= Current.account.captain_assistants.find(params[:assistant_id])
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
