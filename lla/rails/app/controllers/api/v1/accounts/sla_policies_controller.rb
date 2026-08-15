# frozen_string_literal: true

# CRUD chính sách SLA. Phản hồi bọc trong khoá `payload` (hợp đồng từ MIT
# app/javascript/dashboard/api/sla.js và store module tương ứng).
class Api::V1::Accounts::SlaPoliciesController < Api::V1::Accounts::BaseController
  before_action :check_authorization
  before_action :fetch_sla_policy, only: [:show, :update, :destroy]

  def index
    @sla_policies = Current.account.sla_policies
  end

  def show; end

  def create
    @sla_policy = Current.account.sla_policies.new(sla_policy_params)
    @sla_policy.save!
  end

  def update
    @sla_policy.update!(sla_policy_params)
  end

  # Xoá qua DeleteObjectJob để gỡ dần các applied_slas/sla_events nặng và ghi
  # lại ai xoá từ đâu.
  def destroy
    DeleteObjectJob.perform_later(@sla_policy, Current.user, request.ip)
    head :ok
  end

  private

  def check_authorization
    authorize(SlaPolicy)
  end

  def fetch_sla_policy
    @sla_policy = Current.account.sla_policies.find(params[:id])
  end

  def sla_policy_params
    params.require(:sla_policy).permit(:name, :description, :first_response_time_threshold,
                                       :next_response_time_threshold, :resolution_time_threshold,
                                       :only_during_business_hours)
  end
end
