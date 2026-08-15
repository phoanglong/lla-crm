# frozen_string_literal: true

# CRUD trợ lý AI + các góc nhìn vận hành: faq_stats (độ phủ tri thức),
# playground (thử prompt), summary/metrics/drilldown (tổng quan) và danh mục
# tool cho trình soạn scenario.
class Api::V1::Accounts::Captain::AssistantsController < Api::V1::Accounts::Captain::BaseController
  before_action :set_assistant, except: [:index, :create, :tools]
  before_action :check_authorization

  SUMMARY_CACHE_TTL = 12.hours

  def index
    scope = Current.account.captain_assistants.ordered
    scope = scope.where('name ILIKE ?', "%#{params[:searchKey]}%") if params[:searchKey].present?
    @assistants_count = scope.count
    @assistants = paginate(scope)
  end

  def show; end

  def create
    @assistant = Current.account.captain_assistants.create!(assistant_params)
    render :show
  end

  def update
    @assistant.update!(assistant_params)
    render :show
  end

  def destroy
    @assistant.destroy!
    head :no_content
  end

  def faq_stats
    approved = @assistant.responses.approved.count
    suggestions = visible_suggestions_count
    total = approved + suggestions

    render json: {
      approved: approved,
      suggestions: suggestions,
      documents: @assistant.documents.count,
      coverage: total.zero? ? 0 : (approved * 100.0 / total).round
    }
  end

  # Lời chào tổng quan sinh bằng LLM — cache theo NGƯỜI XEM (lời chào có tên
  # riêng); lỗi tạm thời không cache để lần sau thử lại.
  def summary
    cached = Rails.cache.read(summary_cache_key)
    return render json: cached if cached.present?

    result = Captain::OverviewSummaryService.new(
      account: Current.account,
      assistant: @assistant,
      first_name: Current.user.name.to_s.split.first,
      stats: summary_stats_param,
      period: summary_period
    ).perform

    return render json: result, status: :unprocessable_entity if result[:error]

    Rails.cache.write(summary_cache_key, result, expires_in: SUMMARY_CACHE_TTL)
    render json: result
  end

  def playground
    result = playground_service.generate_response(**playground_arguments)
    render json: result
  end

  def metrics
    render json: stats_builder.metrics
  end

  # Danh sách hội thoại phía sau một chỉ số — hoàn thiện ở wave E5 cùng lớp
  # thống kê; trả rỗng để UI không vỡ.
  def drilldown
    render json: { payload: [], meta: { conversation_count: 0 } }
  end

  def tools
    tools = Concerns::CaptainToolsHelpers::BUILT_IN_AGENT_TOOLS +
            Current.account.captain_custom_tools.enabled.map(&:to_tool_metadata)
    render json: { payload: tools }
  end

  private

  def set_assistant
    @assistant = Current.account.captain_assistants.find(params[:id])
  end

  def check_authorization
    authorize(@assistant || Captain::Assistant)
  end

  def assistant_params
    permitted = params.require(:assistant).permit(:name, :description, response_guidelines: [], guardrails: [])
    permitted[:config] = params[:assistant][:config].permit!.to_h if params[:assistant].key?(:config)
    permitted
  end

  # Agent chỉ thấy đề xuất FAQ bắt nguồn từ hội thoại trong inbox mình tham gia
  # (hoặc đề xuất chưa gắn hội thoại nào); administrator thấy tất cả.
  def visible_suggestions_count
    scope = @assistant.faq_suggestions.open
    return scope.count if Current.account_user.administrator?

    inbox_ids = Current.user.assigned_inboxes.ids
    scope.left_joins(observations: :conversation)
         .where('captain_faq_observations.id IS NULL OR conversations.inbox_id IN (?)', inbox_ids)
         .distinct
         .count
  end

  def summary_cache_key
    format('captain_overview_summary/%<account>d/%<assistant>d/%<user>d/%<range>s',
           account: Current.account.id, assistant: @assistant.id, user: Current.user.id, range: params[:range].to_s)
  end

  def summary_stats_param
    return {} if params[:stats].blank?

    params[:stats].permit!.to_h.deep_symbolize_keys
  end

  def summary_period
    days = params[:range].presence || '30'
    { label: "the last #{days} days", starts_on: days.to_i.days.ago.to_date, ends_on: Time.zone.today }
  end

  def playground_service
    if Current.account.feature_enabled?('captain_integration_v2')
      Captain::Assistant::AgentRunnerService.new(assistant: @assistant, source: 'playground')
    else
      Captain::Llm::AssistantChatService.new(assistant: @assistant, source: 'playground')
    end
  end

  def playground_arguments
    if Current.account.feature_enabled?('captain_integration_v2')
      { message_history: playground_history_with_current_message }
    else
      { additional_message: params[:message_content], message_history: playground_message_history }
    end
  end

  def playground_message_history
    Array(params[:message_history]).map do |entry|
      entry.permit(:role, :content, :agent_name).to_h.symbolize_keys
    end
  end

  def playground_history_with_current_message
    history = playground_message_history
    current_message = { role: 'user', content: params[:message_content] }
    return history if history.last == current_message

    history + [current_message]
  end

  def stats_builder
    # Lớp thống kê hiện còn ở EE — chuyển về lla ở wave E5.
    Captain::AssistantStatsBuilder.new(@assistant, params[:range], params[:timezone_offset]&.to_i)
  end
end
