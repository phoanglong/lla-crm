# frozen_string_literal: true

# Quản lý FAQ của trợ lý: tra cứu/lọc/tìm chữ cho mọi thành viên; thêm/sửa/xoá
# dành cho administrator. FAQ tạo tay luôn ở trạng thái approved.
class Api::V1::Accounts::Captain::AssistantResponsesController < Api::V1::Accounts::Captain::BaseController
  before_action :set_response, only: [:show, :update, :destroy]
  before_action :check_authorization

  def index
    scope = Current.account.captain_assistant_responses.includes(:assistant, :documentable).ordered
    scope = apply_filters(scope)
    @responses_count = scope.count
    @responses = paginate(scope)
  end

  def show; end

  def create
    attributes, assistant_id = scoped_response_attributes
    assistant = scoped_assistant(assistant_id)
    @response = Current.account.captain_assistant_responses.create!(attributes.merge(assistant: assistant, status: :approved))
    render :show
  end

  def update
    attributes, assistant_id = scoped_response_attributes
    attributes[:assistant] = scoped_assistant(assistant_id) if assistant_id
    @response.update!(attributes)
    render :show
  end

  def destroy
    @response.destroy!
    head :no_content
  end

  private

  def set_response
    @response = Current.account.captain_assistant_responses.find(params[:id])
  end

  def check_authorization
    authorize(@response || Captain::AssistantResponse)
  end

  def apply_filters(scope)
    scope = scope.by_assistant(params[:assistant_id]) if params[:assistant_id].present?
    scope = scope.where(documentable_id: params[:document_id], documentable_type: 'Captain::Document') if params[:document_id].present?
    search = params[:search].to_s.strip.first(200)
    if search.present?
      term = "%#{ActiveRecord::Base.sanitize_sql_like(search)}%"
      scope = scope.where('question ILIKE :term OR answer ILIKE :term', term: term)
    end
    scope
  end

  def response_params
    params.require(:assistant_response).permit(:question, :answer, :assistant_id)
  end

  def scoped_response_attributes
    attributes = response_params.to_h.symbolize_keys
    [attributes.except(:assistant_id), attributes[:assistant_id]]
  end

  def scoped_assistant(assistant_id)
    return if assistant_id.nil?

    Current.account.captain_assistants.find(assistant_id)
  end
end
