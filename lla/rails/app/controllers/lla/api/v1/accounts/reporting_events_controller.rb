# frozen_string_literal: true

# Account-level reporting event timeline, owned by LLA.
#
# The enterprise controller inherited `Api::V1::Accounts::EnterpriseAccountsController`,
# which is an empty subclass of the ordinary account base — the inheritance carried
# no behaviour, only a name that made the endpoint unavailable with enterprise off.
# This one inherits the ordinary base and is authorised by `ReportPolicy`, so an
# administrator *or* a custom role holding `report_manage` can read it, which is the
# same rule the CSAT and report endpoints already use. The previous
# `check_admin_authorization?` contradicted that rule on this one route.
#
# Every input is bounded. `(params[:page] || 1).to_i` accepted `page=-5` and
# `page=99999999999`; the event-name filter accepted any string; and the inbox and
# user filters accepted identifiers from any account, which the underlying scopes do
# not re-check.
class Lla::Api::V1::Accounts::ReportingEventsController < Api::V1::Accounts::BaseController
  include DateRangeHelper

  RESULTS_PER_PAGE = 25
  MAX_PAGE = 10_000
  # The names come from the two places that actually emit them — the rollup registry
  # and the listener — so adding an event in either place makes it filterable
  # without a second edit here.
  EVENT_NAMES = (ReportingEvents::EventMetricRegistry.event_names + %w[conversation_opened]).freeze
  UNKNOWN_EVENT_NAME = '__lla_unknown_reporting_event__'

  before_action :authorize_reporting
  before_action :set_current_page
  before_action :set_reporting_events

  def index
    @reporting_events = @reporting_events.page(@current_page).per(RESULTS_PER_PAGE)
    @total_count = @reporting_events.total_count
    render 'lla/api/v1/accounts/reporting_events/index', formats: [:json]
  end

  private

  def authorize_reporting
    authorize :report, :view?
  end

  def set_current_page
    requested = params[:page].to_s
    @current_page = requested.match?(/\A\d+\z/) ? requested.to_i.clamp(1, MAX_PAGE) : 1
  end

  def set_reporting_events
    @reporting_events = Current.account.reporting_events
                               .includes(:conversation, :user, :inbox)
                               .filter_by_date_range(range)
                               .filter_by_inbox_id(tenant_inbox_id)
                               .filter_by_user_id(tenant_user_id)
                               .filter_by_name(permitted_event_name)
                               .order(created_at: :desc, id: :desc)
  end

  # An inbox id from another account must not narrow — or fail to narrow — this
  # account's events. Resolving it against the account first means an unknown id
  # filters to nothing rather than being ignored.
  def tenant_inbox_id
    return if params[:inbox_id].blank?

    Current.account.inboxes.where(id: params[:inbox_id]).pick(:id) || -1
  end

  def tenant_user_id
    return if params[:user_id].blank?

    Current.account.users.where(id: params[:user_id]).pick(:id) || -1
  end

  # An unknown name filters to nothing rather than being ignored, so a caller cannot
  # tell the difference between "no such event name" and "no events of that name".
  def permitted_event_name
    return if params[:name].blank?

    name = params[:name].to_s
    EVENT_NAMES.include?(name) ? name : UNKNOWN_EVENT_NAME
  end
end
