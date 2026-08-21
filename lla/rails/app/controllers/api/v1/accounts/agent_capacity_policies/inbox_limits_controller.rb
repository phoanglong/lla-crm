# frozen_string_literal: true

# Giới hạn hội thoại theo inbox trong một chính sách tải.
class Api::V1::Accounts::AgentCapacityPolicies::InboxLimitsController < Api::V1::Accounts::BaseController
  before_action :check_authorization
  before_action :fetch_agent_capacity_policy
  before_action :fetch_inbox_limit, only: [:update, :destroy]

  def create
    inbox = Current.account.inboxes.find(params[:inbox_id])
    if @agent_capacity_policy.inbox_capacity_limits.exists?(inbox_id: inbox.id)
      return render_could_not_create_error(I18n.t('agent_capacity_policy.inbox_already_assigned'))
    end

    @inbox_capacity_limit = @agent_capacity_policy.inbox_capacity_limits.create!(
      inbox: inbox,
      conversation_limit: params[:conversation_limit]
    )
  end

  def update
    @inbox_capacity_limit.update!(conversation_limit: params[:conversation_limit])
  end

  def destroy
    @inbox_capacity_limit.destroy!
    head :no_content
  end

  private

  def check_authorization
    authorize(AgentCapacityPolicy)
  end

  def fetch_agent_capacity_policy
    @agent_capacity_policy = Current.account.agent_capacity_policies.find(params[:agent_capacity_policy_id])
  end

  def fetch_inbox_limit
    @inbox_capacity_limit = @agent_capacity_policy.inbox_capacity_limits.find(params[:id])
  end
end
