# frozen_string_literal: true

# CRUD trợ lý AI + các góc nhìn vận hành: faq_stats (độ phủ tri thức),
# playground (thử prompt), summary/metrics/drilldown (tổng quan) và danh mục
# tool cho trình soạn scenario.
class Api::V1::Accounts::Captain::AssistantsController < Api::V1::Accounts::Captain::BaseController
  include Lla::Captain::AssistantPlaygroundParams

  before_action :set_assistant, except: [:index, :create, :tools]
  before_action :check_authorization

  SUMMARY_CACHE_TTL = 12.hours
  SUMMARY_CACHE_VERSION = 'lla-v2'
  SUMMARY_PROMPT_VERSION = '2026-08-17'
  SUMMARY_RANGES = %w[7 30 90 this_month last_month].freeze
  ASSISTANT_CONFIG_KEYS = %i[
    product_name feature_faq feature_memory feature_citation feature_contact_attributes
    temperature instructions handoff_message resolution_message
  ].freeze
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
    render json: stats_builder.faq_stats
  end

  # Lời chào tổng quan sinh bằng LLM — cache theo NGƯỜI XEM (lời chào có tên
  # riêng); lỗi tạm thời không cache để lần sau thử lại.
  def summary
    snapshot = summary_snapshot
    cached = Rails.cache.read(summary_cache_key(snapshot))
    return render json: cached if cached.present?

    result = Captain::OverviewSummaryService.new(
      account: Current.account,
      assistant: @assistant,
      first_name: Current.user.name.to_s.split.first,
      stats: snapshot.fetch(:stats),
      period: snapshot.fetch(:period)
    ).perform

    return render json: result, status: :unprocessable_entity if result[:error]

    Rails.cache.write(summary_cache_key(snapshot), result, expires_in: SUMMARY_CACHE_TTL)
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

  def drilldown
    unless Captain::AssistantDrilldownBuilder.supported_metric?(params[:metric])
      return render json: { error: 'Unsupported metric' }, status: :unprocessable_entity
    end

    result = Captain::AssistantDrilldownBuilder.new(
      @assistant,
      drilldown_params,
      conversations_scope: authorized_conversations_scope
    ).build
    audit_drilldown(result)
    render json: result
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

  def visible_suggestions_scope
    scope = @assistant.faq_suggestions.open
    return scope if Current.account_user.administrator?

    inbox_ids = Current.user.assigned_inboxes.where(account_id: Current.account.id).ids
    scope.left_joins(observations: :conversation)
         .where('captain_faq_observations.id IS NULL OR conversations.inbox_id IN (?)', inbox_ids)
         .distinct
  end

  def summary_cache_key(snapshot)
    digest = Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(snapshot))
    route = snapshot.fetch(:route)
    [
      'captain_overview_summary', SUMMARY_CACHE_VERSION, Current.account.id, @assistant.id, Current.user.id,
      normalized_range, normalized_timezone_offset, route[:provider], route[:model], route[:source], digest
    ].join('/')
  end

  def summary_snapshot
    @summary_snapshot ||= {
      stats: server_summary_stats,
      period: stats_builder.period,
      source_watermark: stats_builder.source_watermark,
      route: summary_route,
      prompt_version: SUMMARY_PROMPT_VERSION,
      range: normalized_range,
      timezone_offset: normalized_timezone_offset
    }
  end

  def server_summary_stats
    stats_builder.metrics.except(:_meta).merge(knowledge: stats_builder.faq_stats)
  end

  def summary_route
    Llm::FeatureRouter.resolve(feature: 'editor', account: Current.account).slice(:provider, :model, :source)
  end

  def normalized_range
    requested = params[:range].to_s
    SUMMARY_RANGES.include?(requested) ? requested : Captain::AssistantStatsWindow::DEFAULT_RANGE
  end

  def normalized_timezone_offset
    parsed = Float(params[:timezone_offset], exception: false)
    return 0.0 unless parsed&.finite?

    (parsed.clamp(-14.0, 14.0) * 4).round / 4.0
  end

  def stats_builder
    @stats_builder ||= Captain::AssistantStatsBuilder.new(
      @assistant,
      normalized_range,
      normalized_timezone_offset,
      suggestions_scope: visible_suggestions_scope,
      conversations_scope: authorized_conversations_scope
    )
  end

  def authorized_conversations_scope
    @authorized_conversations_scope ||= Conversations::PermissionFilterService.new(
      Current.account.conversations,
      Current.user,
      Current.account
    ).perform
  end

  def drilldown_params
    params.permit(:metric, :range, :timezone_offset, :page, :per_page)
  end

  def audit_drilldown(result)
    metadata = {
      account_id: Current.account.id,
      assistant_id: @assistant.id,
      user_id: Current.user.id,
      metric: params[:metric].to_s,
      page: result.dig(:meta, :current_page),
      returned_count: result.fetch(:payload).size
    }
    ActiveSupport::Notifications.instrument('lla.captain.assistant_drilldown', metadata)
    Rails.logger.info("LLA Captain drilldown viewed #{metadata.map { |key, value| "#{key}=#{value}" }.join(' ')}")
  end
end
