# frozen_string_literal: true

# Hàng chờ duyệt FAQ do AI đề xuất: sửa, duyệt thành FAQ chính thức hoặc bỏ.
# Agent chỉ thấy/duyệt đề xuất bắt nguồn từ hội thoại trong inbox mình tham gia.
class Api::V1::Accounts::Captain::FaqSuggestionsController < Api::V1::Accounts::Captain::BaseController
  before_action :set_suggestion, only: [:show, :update, :approve, :dismiss]
  before_action :check_authorization

  RESULTS_PER_PAGE = 25
  SOURCE_PREVIEW_LIMIT = 50

  def index
    @current_page = permitted_params[:page].presence || 1
    filtered = apply_filters(visible_suggestions.ordered)
    @suggestions_count = filtered.count
    @suggestions = filtered.page(@current_page).per(RESULTS_PER_PAGE)
  end

  def show
    @observations = visible_observations(@suggestion)
  end

  def update
    @suggestion.with_lock do
      raise ActiveRecord::RecordNotFound unless @suggestion.open?

      @suggestion.update!(suggestion_params)
    end
    render :show_suggestion
  end

  # Duyệt: cho phép sửa lần cuối rồi ghi thành FAQ chính thức (approved) của
  # trợ lý; đề xuất chuyển trạng thái approved.
  def approve
    attributes = params[:faq_suggestion].present? ? suggestion_params : {}
    @response = Captain::FaqSuggestionApprovalService.new(@suggestion, attributes).perform
    render 'api/v1/accounts/captain/assistant_responses/show'
  end

  def dismiss
    @suggestion.with_lock do
      raise ActiveRecord::RecordNotFound unless @suggestion.open?

      @suggestion.dismissed!
    end
    render :show_suggestion
  end

  private

  def set_suggestion
    @suggestion = visible_suggestions.find(params[:id])
  end

  def check_authorization
    authorize(@suggestion || Captain::FaqSuggestion)
  end

  def apply_filters(scope)
    scope = scope.where(assistant_id: permitted_params[:assistant_id]) if permitted_params[:assistant_id].present?
    scope = scope.where(status: permitted_params[:status]) if permitted_params[:status].present?
    return scope if permitted_params[:search].blank?

    search = "%#{ActiveRecord::Base.sanitize_sql_like(permitted_params[:search].to_s.first(200))}%"
    scope.where('question ILIKE :search OR answer ILIKE :search', search: search)
  end

  def visible_suggestions
    scope = Current.account.captain_faq_suggestions
    return scope if Current.account_user.administrator?

    scope.left_joins(observations: :conversation)
         .where('captain_faq_observations.id IS NULL OR conversations.inbox_id IN (?)', Current.user.assigned_inboxes.select(:id))
         .distinct
  end

  def visible_observations(suggestion)
    scope = suggestion.observations.includes(:conversation)
    unless Current.account_user.administrator?
      scope = scope.joins(:conversation).where(conversations: { inbox_id: Current.user.assigned_inboxes.select(:id) })
    end

    scope.order(created_at: :desc).limit(SOURCE_PREVIEW_LIMIT)
  end

  def permitted_params
    params.permit(:id, :assistant_id, :page, :status, :search)
  end

  def suggestion_params
    params.require(:faq_suggestion).permit(:question, :answer)
  end
end
