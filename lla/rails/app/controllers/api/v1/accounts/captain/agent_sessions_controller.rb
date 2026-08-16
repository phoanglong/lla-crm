# frozen_string_literal: true

class Api::V1::Accounts::Captain::AgentSessionsController < Api::V1::Accounts::BaseController
  before_action :set_message
  before_action :authorize_conversation

  def show
    @agent_session = authorized_sessions.find_by(result_type: 'Message', result_id: @message.id)
    return head :not_found if @agent_session.blank?

    @citations = @agent_session.assistant.responses
                               .where(id: @agent_session.faq_ids)
                               .includes(:documentable)
    @scenario_titles = @agent_session.assistant.scenarios
                                     .where(id: @agent_session.scenario_ids)
                                     .pluck(:id, :title).to_h
    @run_context = Captain::Assistant::SessionPresenter.new(@agent_session).run_context
  end

  private

  def set_message
    @message = Current.account.messages.includes(conversation: :inbox).find(params[:id])
  end

  def authorize_conversation
    authorize @message.conversation, :show?
  end

  def authorized_sessions
    Current.account.captain_agent_sessions.where(
      assistant_id: configured_assistant_id,
      session_type: Captain::AgentSession.session_types.fetch('assistant'),
      subject_type: 'Conversation',
      subject_id: @message.conversation_id
    )
  end

  def configured_assistant_id
    CaptainInbox.joins(:captain_assistant)
                .where(
                  inbox_id: @message.conversation.inbox_id,
                  captain_assistants: { account_id: Current.account.id }
                ).pick(:captain_assistant_id)
  end
end
