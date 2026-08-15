# frozen_string_literal: true

# Hàng chờ duyệt FAQ do AI đề xuất: sửa, duyệt thành FAQ chính thức hoặc bỏ.
# Agent chỉ thấy/duyệt đề xuất bắt nguồn từ hội thoại trong inbox mình tham gia.
class Api::V1::Accounts::Captain::FaqSuggestionsController < Api::V1::Accounts::Captain::BaseController
  before_action :set_suggestion, only: [:show, :update, :approve, :dismiss]
  before_action :check_authorization

  def index
    scope = visible_suggestions.open.ordered
    scope = scope.where(assistant_id: params[:assistant_id]) if params[:assistant_id].present?
    @suggestions_count = scope.count
    @suggestions = paginate(scope)
  end

  def show
    @observations = visible_observations(@suggestion)
  end

  def update
    @suggestion.update!(suggestion_params)
    render :show_suggestion
  end

  # Duyệt: cho phép sửa lần cuối rồi ghi thành FAQ chính thức (approved) của
  # trợ lý; đề xuất chuyển trạng thái approved.
  def approve
    @suggestion.update!(suggestion_params) if params[:faq_suggestion].present?
    @response = @suggestion.assistant.responses.create!(
      account: @suggestion.account,
      question: @suggestion.question,
      answer: @suggestion.answer,
      status: :approved
    )
    @suggestion.approved!
    render 'api/v1/accounts/captain/assistant_responses/show'
  end

  def dismiss
    @suggestion.dismissed!
    render :show_suggestion
  end

  private

  def set_suggestion
    @suggestion = visible_suggestions.find(params[:id])
  end

  def check_authorization
    authorize(@suggestion || Captain::FaqSuggestion)
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
    return scope if Current.account_user.administrator?

    scope.joins(:conversation).where(conversations: { inbox_id: Current.user.assigned_inboxes.select(:id) })
  end

  def suggestion_params
    params.require(:faq_suggestion).permit(:question, :answer)
  end
end
