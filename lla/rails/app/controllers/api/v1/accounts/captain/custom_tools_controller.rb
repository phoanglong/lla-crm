# frozen_string_literal: true

class Api::V1::Accounts::Captain::CustomToolsController < Api::V1::Accounts::BaseController
  before_action :ensure_custom_tools_enabled
  before_action :set_custom_tool, only: [:show, :update, :destroy]
  before_action :authorize_custom_tool

  def index
    @custom_tools = account_custom_tools.order(updated_at: :desc, id: :desc)
  end

  def show; end

  def create
    @custom_tool = account_custom_tools.create!(custom_tool_params)
  rescue Captain::CustomTool::LimitExceededError => e
    render_could_not_create_error(e.message)
  end

  def update
    @custom_tool.update!(safe_update_params)
  end

  def destroy
    @custom_tool.destroy!
    head :no_content
  end

  def test
    tool = account_custom_tools.new(custom_tool_params)
    tool.validate!
    result = Captain::Tools::HttpTool.new(nil, tool).perform_test(account: Current.account)
    render json: result
  rescue ActiveRecord::RecordInvalid
    render json: { error: 'Custom tool configuration is invalid' }, status: :unprocessable_content
  rescue StandardError => e
    ChatwootExceptionTracker.new(
      StandardError.new("Captain custom tool test failed: #{e.class.name}"),
      account: Current.account
    ).capture_exception
    Rails.logger.warn("LLA custom tool test failed account_id=#{Current.account.id} error=#{e.class.name}")
    render json: { error: 'Custom tool test failed' }, status: :unprocessable_content
  end

  private

  def ensure_custom_tools_enabled
    return if Captain::Assistant.custom_http_tools_enabled_for?(Current.account)

    render json: { error: 'Custom tools are not enabled for this account' }, status: :forbidden
  end

  def set_custom_tool
    @custom_tool = account_custom_tools.find(params[:id])
  end

  def authorize_custom_tool
    authorize(@custom_tool || Captain::CustomTool)
  end

  def account_custom_tools
    @account_custom_tools ||= Current.account.captain_custom_tools
  end

  def safe_update_params
    attributes = custom_tool_params.to_h
    requested_auth_type = attributes.fetch('auth_type', @custom_tool.auth_type)
    attributes.delete('auth_config') if preserve_existing_credential?(requested_auth_type, attributes)
    attributes
  end

  def preserve_existing_credential?(requested_auth_type, attributes)
    requested_auth_type != 'none' && @custom_tool.auth_configured? && attributes['auth_config'].blank?
  end

  def custom_tool_params
    params.require(:custom_tool).permit(
      :title,
      :description,
      :endpoint_url,
      :http_method,
      :request_template,
      :response_template,
      :auth_type,
      :enabled,
      auth_config: {},
      param_schema: [:name, :type, :description, :required]
    )
  end
end
