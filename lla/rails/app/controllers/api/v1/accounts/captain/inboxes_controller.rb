# frozen_string_literal: true

# Gắn/tháo trợ lý AI với inbox (lồng dưới assistants). Quyền đi theo
# Captain::AssistantPolicy: xem tự do, thay đổi cần administrator.
class Api::V1::Accounts::Captain::InboxesController < Api::V1::Accounts::Captain::BaseController
  before_action :set_assistant
  before_action :check_authorization

  def index
    @inboxes = @assistant.inboxes
  end

  def create
    inbox = Current.account.inboxes.find(params.require(:inbox)[:inbox_id])
    @assistant.captain_inboxes.create!(inbox: inbox)
    @inbox = inbox
    render :show
  end

  def destroy
    @assistant.captain_inboxes.find_by!(inbox_id: params[:inbox_id]).destroy!
    head :no_content
  end

  private

  def set_assistant
    @assistant = Current.account.captain_assistants.find(params[:assistant_id])
  end

  def check_authorization
    action = action_name == 'index' ? :show? : :update?
    authorize(@assistant, action)
  end
end
