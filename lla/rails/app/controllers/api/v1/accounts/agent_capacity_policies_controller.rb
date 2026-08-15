# frozen_string_literal: true

# CRUD chính sách tải của agent. Hợp đồng API theo MIT
# app/javascript/dashboard/api/agentCapacityPolicies.js và store module tương ứng.
class Api::V1::Accounts::AgentCapacityPoliciesController < Api::V1::Accounts::BaseController
  before_action :check_authorization
  before_action :fetch_agent_capacity_policy, only: [:show, :update, :destroy]

  def index
    @agent_capacity_policies = Current.account.agent_capacity_policies
  end

  def show; end

  def create
    @agent_capacity_policy = Current.account.agent_capacity_policies.new(agent_capacity_policy_params)
    @agent_capacity_policy.save!
  end

  def update
    @agent_capacity_policy.update!(agent_capacity_policy_params)
  end

  def destroy
    @agent_capacity_policy.destroy!
    head :ok
  end

  private

  def check_authorization
    authorize(AgentCapacityPolicy)
  end

  def fetch_agent_capacity_policy
    @agent_capacity_policy = Current.account.agent_capacity_policies.find(params[:id])
  end

  def agent_capacity_policy_params
    params.require(:agent_capacity_policy).permit(:name, :description, exclusion_rules: {})
  end
end
