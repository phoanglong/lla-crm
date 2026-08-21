# frozen_string_literal: true

class Api::V1::Accounts::Captain::BulkActionsController < Api::V1::Accounts::BaseController
  before_action -> { check_authorization(Captain::Assistant) }

  def create
    result = bulk_action_service.perform
    render json: result, status: result[:success] ? :ok : :unprocessable_content
  rescue Lla::Captain::BulkActionService::InvalidRequest => e
    render json: { success: false, error: e.message }, status: :unprocessable_content
  rescue Lla::Captain::BulkActionService::Conflict, Lla::Captain::BulkActionService::InProgress => e
    render json: { success: false, error: e.message }, status: :conflict
  rescue Lla::Captain::BulkActionService::OperationFailed
    render json: { success: false, error: 'Bulk operation failed' }, status: :unprocessable_content
  end

  private

  def bulk_action_service
    Lla::Captain::BulkActionService.new(
      account: Current.account,
      user: Current.user,
      resource_type: permitted_params[:type],
      action: permitted_params.dig(:fields, :status),
      ids: permitted_params[:ids],
      operation_id: request.headers['Idempotency-Key'].presence || permitted_params[:operation_id]
    )
  end

  def permitted_params
    params.permit(:type, :operation_id, ids: [], fields: [:status])
  end
end
