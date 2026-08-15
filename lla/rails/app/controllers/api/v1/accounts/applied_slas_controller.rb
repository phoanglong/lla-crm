# frozen_string_literal: true

# Báo cáo SLA: danh sách vi phạm (index), số liệu tổng hợp (metrics) và CSV
# (download). Hợp đồng từ MIT app/javascript/dashboard/api/slaReports.js và spec.
class Api::V1::Accounts::AppliedSlasController < Api::V1::Accounts::BaseController
  RESULTS_PER_PAGE = 25

  def index
    @applied_slas = breached_slas.order(created_at: :desc)
                                 .page(params[:page])
                                 .per(RESULTS_PER_PAGE)
    @count = breached_slas.count
  end

  # Metrics tổng hợp KHÔNG lọc theo agent (hợp đồng từ spec MIT): tỉ lệ hit của
  # tài khoản không đổi theo người được gán.
  def metrics
    scope = filtered_slas(apply_agent_filter: false)
    total = scope.count
    misses = scope.where(sla_status: [:missed, :active_with_misses]).count

    render json: {
      total_applied_slas: total,
      number_of_sla_misses: misses,
      hit_rate: hit_rate(total, misses)
    }
  end

  def download
    csv = CSV.generate do |rows|
      rows << csv_headers
      breached_slas.order(created_at: :desc).each { |applied_sla| rows << csv_row(applied_sla) }
    end

    send_data csv, filename: 'breached_conversation.csv', type: 'text/csv'
    # Header mặc định của Rails thêm dấu nháy quanh tên file; giao diện tải về
    # đối chiếu đúng chuỗi không nháy.
    response.headers['Content-Disposition'] = 'attachment; filename=breached_conversation.csv'
  end

  private

  def filtered_slas(apply_agent_filter: true)
    scope = Current.account.applied_slas.with_sla_applicable_conversation.joins(:conversation)
    scope = apply_date_range(scope)
    scope = scope.where(sla_policy_id: params[:sla_policy_id]) if params[:sla_policy_id].present?
    scope = apply_conversation_filters(scope, apply_agent_filter: apply_agent_filter)
    apply_label_filter(scope)
  end

  def apply_conversation_filters(scope, apply_agent_filter:)
    scope = scope.where(conversations: { assignee_id: agent_ids }) if apply_agent_filter && agent_ids.present?
    scope = scope.where(conversations: { inbox_id: params[:inbox_id] }) if params[:inbox_id].present?
    scope = scope.where(conversations: { team_id: params[:team_id] }) if params[:team_id].present?
    scope
  end

  def breached_slas
    filtered_slas.where(sla_status: [:missed, :active_with_misses])
  end

  def apply_date_range(scope)
    scope = scope.where('applied_slas.created_at >= ?', Time.zone.at(params[:since].to_i)) if params[:since].present?
    scope = scope.where('applied_slas.created_at <= ?', Time.zone.at(params[:until].to_i)) if params[:until].present?
    scope
  end

  # Giao diện gửi assigned_agent_id, spec dùng agent_ids — nhận cả hai.
  def agent_ids
    params[:agent_ids].presence || params[:assigned_agent_id].presence
  end

  def apply_label_filter(scope)
    return scope if params[:label_list].blank?

    conversation_ids = Current.account.conversations.tagged_with(params[:label_list], any: true).pluck(:id)
    scope.where(conversation_id: conversation_ids)
  end

  def hit_rate(total, misses)
    return '0%' if total.zero?

    rate = ((total - misses).to_f / total * 100).round(2)
    rate == 100 ? '100%' : "#{rate}%"
  end

  def csv_headers
    %w[conversation_id sla_policy_breached assignee team inbox labels conversation_link breached_events]
      .map { |key| I18n.t("reports.sla_csv.#{key}") }
  end

  def csv_row(applied_sla)
    conversation = applied_sla.conversation
    [
      conversation.display_id,
      applied_sla.sla_policy.name,
      conversation.assignee&.name,
      conversation.team&.name,
      conversation.inbox.name,
      conversation.label_list.join(', '),
      app_account_conversation_url(account_id: Current.account.id, id: conversation.display_id),
      applied_sla.sla_events.map(&:event_type).uniq.join(', ')
    ]
  end
end
