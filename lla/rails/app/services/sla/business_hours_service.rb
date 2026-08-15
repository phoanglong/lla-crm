# frozen_string_literal: true

# Tính hạn chót khi SLA chỉ đếm trong giờ làm việc của inbox.
#
# Hợp đồng từ spec MIT spec/enterprise/services/sla/business_hours_service_spec.rb
# (đã chuyển sang spec/lla): ngoài giờ thì dồn sang khung giờ mở kế tiếp; ngày
# open_all_day tính đủ 24 giờ; inbox tắt giờ làm việc hoặc đóng cả tuần thì trả
# hạn theo đồng hồ thường; mỗi lần tính chỉ nạp giờ làm việc MỘT lần (index_by,
# không find_by theo từng ngày).
class Sla::BusinessHoursService
  pattr_initialize [:inbox!, :start_time!, :threshold_seconds!, :working_hours_by_day]

  MAX_DAYS_SCANNED = 366

  def deadline
    return start_time + threshold_seconds unless business_hours_applicable?

    remaining = threshold_seconds.to_f
    cursor = start_time.in_time_zone(timezone)

    MAX_DAYS_SCANNED.times do
      cursor, remaining, done = advance_through_day(cursor, remaining)
      return cursor if done
    end

    raise ArgumentError, "SLA threshold #{threshold_seconds}s không xếp được vào giờ làm việc của inbox #{inbox.id}"
  end

  private

  def business_hours_applicable?
    inbox.working_hours_enabled? && hours_by_day.values.any? { |wh| !wh.closed_all_day? }
  end

  def timezone
    inbox.timezone
  end

  def hours_by_day
    @hours_by_day ||= working_hours_by_day || inbox.working_hours.index_by(&:day_of_week)
  end

  # Đi hết phần giờ làm việc còn lại của ngày chứa cursor; done=true khi hạn
  # rơi trong ngày đó.
  def advance_through_day(cursor, remaining)
    window = day_window(cursor.to_date)
    return [next_day(cursor), remaining, false] if window.nil? || cursor >= window[:close]

    cursor = window[:open] if cursor < window[:open]
    available = window[:close] - cursor
    return [cursor + remaining, remaining, true] if remaining <= available

    [next_day(cursor), remaining - available, false]
  end

  def next_day(cursor)
    (cursor.to_date + 1).in_time_zone(timezone)
  end

  # Khung mở cửa của một ngày theo múi giờ inbox; nil nếu đóng cả ngày.
  # open_all_day = trọn 24 giờ, tính đến hết phút cuối (nửa đêm hôm sau).
  def day_window(date)
    working_hour = hours_by_day[date.wday]
    return if working_hour.nil? || working_hour.closed_all_day?

    day_start = date.in_time_zone(timezone)
    return { open: day_start, close: day_start + 1.day } if working_hour.open_all_day?

    {
      open: day_start + hour_offset(working_hour.open_hour, working_hour.open_minutes),
      close: day_start + hour_offset(working_hour.close_hour, working_hour.close_minutes)
    }
  end

  def hour_offset(hours, minutes)
    hours.to_i.hours + minutes.to_i.minutes
  end
end
