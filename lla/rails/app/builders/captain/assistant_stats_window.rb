# frozen_string_literal: true

# Resolves non-overlapping reporting windows for Captain assistant metrics.
# Every range is half-open [start, finish), which gives a timestamp at a shared
# boundary exactly one owner and keeps cards and drilldowns on the same cohort.
class Captain::AssistantStatsWindow
  include TimezoneHelper

  DEFAULT_RANGE = '30'
  ALLOWED_RANGES = %w[7 30 90 this_month last_month].freeze

  attr_reader :range, :timezone_offset

  def initialize(range = DEFAULT_RANGE, timezone_offset = nil)
    @range = ALLOWED_RANGES.include?(range.to_s) ? range.to_s : DEFAULT_RANGE
    @timezone_offset = normalize_timezone_offset(timezone_offset)
    @timezone = timezone_name_from_offset(@timezone_offset) || 'UTC'
  end

  def current
    resolved_ranges.fetch(:current)
  end

  def previous
    resolved_ranges.fetch(:previous)
  end

  def period
    {
      label: period_label,
      starts_on: current.begin.to_date,
      ends_on: display_end(current),
      end_exclusive: true
    }
  end

  private

  def normalize_timezone_offset(value)
    parsed = value.is_a?(Numeric) ? value.to_f : Float(value, exception: false)
    return 0.0 unless parsed&.finite?

    (parsed.clamp(-14.0, 14.0) * 4).round / 4.0
  end

  def resolved_ranges
    @resolved_ranges ||= case range
                         when 'this_month' then this_month_ranges
                         when 'last_month' then last_month_ranges
                         else day_ranges
                         end
  end

  def now
    @now ||= Time.current.in_time_zone(@timezone)
  end

  def this_month_ranges
    current_start = now.beginning_of_month
    previous_start = current_start - 1.month
    elapsed = now - current_start
    previous_finish = [previous_start + elapsed, current_start].min

    { current: current_start...now, previous: previous_start...previous_finish }
  end

  def last_month_ranges
    current_finish = now.beginning_of_month
    current_start = current_finish - 1.month
    previous_start = current_start - 1.month

    { current: current_start...current_finish, previous: previous_start...current_start }
  end

  def day_ranges
    days = range.to_i.days
    current_start = now - days
    previous_start = current_start - days

    { current: current_start...now, previous: previous_start...current_start }
  end

  def display_end(window)
    (window.end - 1.second).to_date
  end

  def period_label
    { 'this_month' => 'this month', 'last_month' => 'last month' }[range] || "the last #{range.to_i} days"
  end
end
