# frozen_string_literal: true

# CRUD trợ lý AI + các góc nhìn vận hành: faq_stats (độ phủ tri thức),
# playground (thử prompt), summary/metrics/drilldown (tổng quan) và danh mục
# tool cho trình soạn scenario.
class Api::V1::Accounts::Captain::AssistantsController < Api::V1::Accounts::Captain::BaseController
  include Lla::Captain::AssistantPlaygroundParams

  before_action :set_assistant, except: [:index, :create, :tools]
  before_action :check_authorization

  SUMMARY_CACHE_TTL = 12.hours
  SUMMARY_RANGES = %w[7 30 90].freeze
  SUMMARY_STATS_SCHEMA = {
    conversations_handled: [:current],
    hours_saved: [:current],
    auto_resolution_rate: [:current, :trend],
    handoff_rate: [:current, :trend],
    reopen_rate: [:current, :trend],
    knowledge: [:coverage, :approved, :documents]
  }.freeze
  ASSISTANT_CONFIG_KEYS = %i[
    product_name feature_faq feature_memory feature_citation feature_contact_attributes
    temperature instructions handoff_message resolution_message
  ].freeze
  MAX_SUMMARY_STAT_ABS = 1_000_000_000
  MAX_PLAYGROUND_MESSAGE_BYTES = 20.kilobytes
  MAX_PLAYGROUND_HISTORY_BYTES = 100.kilobytes
  MAX_PLAYGROUND_HISTORY_ITEMS = 50
  PLAYGROUND_ROLES = %w[user assistant].freeze

  def index
    scope = Current.account.captain_assistants.ordered
    search = params[:searchKey].to_s.strip.first(100)
    scope = scope.where('name ILIKE ?', "%#{ActiveRecord::Base.sanitize_sql_like(search)}%") if search.present?
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
    return render_invalid_playground unless valid_playground_payload?

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
    tools = Concerns::CaptainToolsHelpers::BUILT_IN_AGENT_TOOLS.dup
    if Captain::Assistant.custom_http_tools_enabled_for?(Current.account)
      tools += Current.account.captain_custom_tools.enabled.map(&:to_tool_metadata)
    end
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
    permitted[:config] = params[:assistant][:config].permit(*ASSISTANT_CONFIG_KEYS).to_h if params[:assistant].key?(:config)
    permitted
  end

  # Agent chỉ thấy đề xuất FAQ bắt nguồn từ hội thoại trong inbox mình tham gia
  # (hoặc đề xuất chưa gắn hội thoại nào); administrator thấy tất cả.
  def visible_suggestions_count
    scope = @assistant.faq_suggestions.open
    return scope.count if Current.account_user.administrator?

    inbox_ids = Current.user.assigned_inboxes.where(account_id: Current.account.id).ids
    scope.left_joins(observations: :conversation)
         .where('captain_faq_observations.id IS NULL OR conversations.inbox_id IN (?)', inbox_ids)
         .distinct
         .count
  end

  def summary_cache_key
    format('captain_overview_summary/%<account>d/%<assistant>d/%<user>d/%<range>s',
           account: Current.account.id, assistant: @assistant.id, user: Current.user.id, range: summary_range)
  end

  def summary_stats_param
    @summary_stats_param ||= normalize_summary_stats
  end

  def normalize_summary_stats
    return {} if params[:stats].blank? || !params[:stats].respond_to?(:permit)

    permitted = params[:stats].permit(SUMMARY_STATS_SCHEMA).to_h.deep_symbolize_keys
    permitted.each_with_object({}) do |(group, values), normalized|
      next unless values.is_a?(Hash)

      normalized[group] = normalize_summary_group(values)
    end
  end

  def normalize_summary_group(values)
    values.each_with_object({}) do |(key, value), normalized|
      number = value.is_a?(Numeric) ? value : Float(value, exception: false)
      normalized[key] = number.clamp(-MAX_SUMMARY_STAT_ABS, MAX_SUMMARY_STAT_ABS) if number&.finite?
    end
  end

  def summary_period
    days = summary_range
    { label: "the last #{days} days", starts_on: days.to_i.days.ago.to_date, ends_on: Time.zone.today }
  end

  def summary_range
    requested = params[:range].to_s
    SUMMARY_RANGES.include?(requested) ? requested : '30'
  end

  def stats_builder
    # Lớp thống kê hiện còn ở EE — chuyển về lla ở wave E5.
    offset = params[:timezone_offset].to_i.clamp(-840, 840)
    Captain::AssistantStatsBuilder.new(@assistant, summary_range, offset)
  end
end
