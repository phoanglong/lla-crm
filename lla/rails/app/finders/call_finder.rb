# frozen_string_literal: true

class CallFinder
  RESULTS_PER_PAGE = 25
  MAX_PAGE = 10_000
  MAX_RANGE = 90.days

  def initialize(current_user, current_account, params)
    @current_user = current_user
    @current_account = current_account
    @account_user = current_account.account_users.find_by(user_id: current_user.id)
    @params = params
  end

  def perform
    @calls = @current_account.calls
    filter_by_visibility
    filter_by_status
    filter_by_direction
    filter_by_integer(:inbox_id)
    filter_by_integer(:accepted_by_agent_id, param: :agent_id)
    filter_by_date_range

    { calls: paginated_calls, count: @calls.count }
  end

  private

  def filter_by_visibility
    return if account_wide_access?

    @calls = @calls.where(accepted_by_agent_id: @current_user.id, conversation_id: accessible_conversations)
  end

  def accessible_conversations
    Conversations::PermissionFilterService.new(
      @current_account.conversations, @current_user, @current_account
    ).perform.select(:id)
  end

  def account_wide_access?
    @account_user&.administrator? || @account_user&.custom_role&.permissions&.include?('report_manage')
  end

  def filter_by_status
    return if @params[:status].blank?

    status = Call.status_from_display(@params[:status])
    raise ActionController::BadRequest, 'invalid call status' unless Call::STATUSES.include?(status)

    @calls = @calls.where(status: status)
  end

  def filter_by_direction
    return if @params[:direction].blank?

    direction = Call.direction_from_label(@params[:direction])
    raise ActionController::BadRequest, 'invalid call direction' unless Call.directions.key?(direction)

    @calls = @calls.where(direction: direction)
  end

  def filter_by_integer(column, param: column)
    return if @params[param].blank?

    value = Integer(@params[param], exception: false)
    raise ActionController::BadRequest, "invalid #{param}" unless value&.positive?

    @calls = @calls.where(column => value)
  end

  def filter_by_date_range
    return if @params[:since].blank? && @params[:until].blank?
    raise ActionController::BadRequest, 'since and until are required together' if @params[:since].blank? || @params[:until].blank?

    since_time = timestamp(:since)
    until_time = timestamp(:until)
    raise ActionController::BadRequest, 'invalid call date range' if since_time >= until_time || until_time - since_time > MAX_RANGE

    @calls = @calls.where(created_at: since_time...until_time)
  end

  def timestamp(name)
    value = Integer(@params[name], exception: false)
    raise ActionController::BadRequest, "invalid #{name}" unless value

    Time.zone.at(value)
  rescue ArgumentError, RangeError
    raise ActionController::BadRequest, "invalid #{name}"
  end

  def paginated_calls
    @calls.includes(:contact, :conversation, :accepted_by_agent, inbox: :channel)
          .order(created_at: :desc, id: :desc)
          .page(page_number)
          .per(RESULTS_PER_PAGE)
  end

  def page_number
    Integer(@params[:page], exception: false).to_i.clamp(1, MAX_PAGE)
  end
end
