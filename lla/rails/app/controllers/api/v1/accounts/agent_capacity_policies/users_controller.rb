# frozen_string_literal: true

# Gán/gỡ agent vào chính sách tải. `id` trên route là user_id (hợp đồng từ MIT
# agentCapacityPolicies.js: removeUser(policyId, userId)).
class Api::V1::Accounts::AgentCapacityPolicies::UsersController < Api::V1::Accounts::BaseController
  before_action :check_authorization
  before_action :fetch_agent_capacity_policy

  def index
    @users = @agent_capacity_policy.users
  end

  def create
    account_user = Current.account.account_users.find_by!(user_id: params[:user_id])
    account_user.update!(agent_capacity_policy: @agent_capacity_policy)
    @users = @agent_capacity_policy.users
  end

  def destroy
    account_user = Current.account.account_users.find_by!(user_id: params[:id], agent_capacity_policy_id: @agent_capacity_policy.id)
    account_user.update!(agent_capacity_policy: nil)
    head :ok
  end

  private

  def check_authorization
    authorize(AgentCapacityPolicy)
  end

  def fetch_agent_capacity_policy
    @agent_capacity_policy = Current.account.agent_capacity_policies.find(params[:agent_capacity_policy_id])
  end
end
