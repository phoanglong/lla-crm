# frozen_string_literal: true

class Api::V1::Accounts::Captain::MessageReportsController < Api::V1::Accounts::BaseController
  before_action :ensure_feedback_enabled
  before_action :validate_description_size
  before_action :set_message
  before_action :authorize_conversation
  before_action :ensure_public_captain_message

  def create
    @message_report = @message.message_reports.find_or_create_by!(
      account_id: Current.account.id,
      user_id: Current.user.id
    ) do |report|
      report.report_reason = permitted_params[:report_reason]
      report.description = permitted_params[:description]
    end
    @revised = !@message_report.previously_new_record?
    if @revised
      @message_report.update!(
        report_reason: permitted_params[:report_reason],
        description: permitted_params[:description]
      )
    end

    log_feedback_write
    render :create, status: @revised ? :ok : :created
  end

  private

  def ensure_feedback_enabled
    return if Current.account.feature_enabled?('captain_integration')

    render json: { error: 'Not available' }, status: :not_found
  end

  def validate_description_size
    return if params[:description].to_s.bytesize <= Captain::MessageReport::MAX_DESCRIPTION_INPUT_BYTES

    render json: { error: 'Description is too large' }, status: :unprocessable_content
  end

  def set_message
    @message = Current.account.messages.find(permitted_params[:message_id])
  end

  def authorize_conversation
    authorize @message.conversation, :show?
  end

  def ensure_public_captain_message
    valid = @message.sender_type == 'Captain::Assistant' && @message.outgoing? && !@message.private?
    return if valid

    render json: { error: 'Only public Captain messages can be reported' }, status: :unprocessable_content
  end

  def permitted_params
    params.permit(:message_id, :report_reason, :description)
  end

  def log_feedback_write
    Rails.logger.info(
      "LLA Captain feedback stored account_id=#{Current.account.id} message_id=#{@message.id} " \
      "user_id=#{Current.user.id} reason=#{@message_report.report_reason} revised=#{@revised} external_egress=false"
    )
  end
end
