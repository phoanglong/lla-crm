# frozen_string_literal: true

# Đưa một sự kiện đã xác thực về đúng đường xử lý của nền tảng — và **kèm theo tài khoản**.
#
# Đường cũ phải đoán tenant từ `page_id`/`instagram_id` toàn cục, nên một page xuất hiện ở hai
# tenant thì tin nhân đôi sang cả hai. Ở đây tenant đã biết từ trước khi mở gói tin, nên nó
# được truyền xuống và việc dựng tin nhắn bị giới hạn trong đúng tài khoản đó.
class Lla::Platform::EventDispatcher
  def initialize(platform_app, payload)
    @app = platform_app
    @payload = payload
  end

  def call
    case @app.platform
    when 'facebook' then dispatch_facebook
    when 'instagram' then dispatch_instagram
    when 'tiktok' then dispatch_tiktok
    end
  end

  private

  def account_id
    @app.account_id
  end

  # Cùng cách tách gói của gem facebook-messenger (Server#trigger): một `entry` có thể gộp
  # nhiều `messaging`, và mỗi `messaging` là một sự kiện. Gói lại dưới khoá `messaging` vì đó
  # là hình dạng `Integrations::Facebook::MessageParser` đọc được — cũng chính là hình dạng
  # gem sinh ra khi nó tuần tự hoá đối tượng sự kiện.
  def dispatch_facebook
    each_messaging do |messaging|
      event = { messaging: messaging }.to_json
      if messaging.dig('message', 'is_echo')
        # Trễ 2 giây để bản vọng của chính mình không về trước khi lệnh gửi kịp hoàn tất —
        # cùng lý do như đường webhook cũ.
        Webhooks::FacebookEventsJob.set(wait: 2.seconds).perform_later(event, account_id)
      else
        Webhooks::FacebookEventsJob.perform_later(event, account_id)
      end
    end
  end

  # Instagram gửi cả mảng `entry` một lượt và job tự tách; giữ nguyên hình dạng đó.
  def dispatch_instagram
    entries = Array(@payload['entry'])
    return if entries.blank?

    if entries.any? { |entry| Array(entry['messaging']).any? { |m| m.dig('message', 'is_echo') } }
      Webhooks::InstagramEventsJob.set(wait: 2.seconds).perform_later(entries, account_id)
    else
      Webhooks::InstagramEventsJob.perform_later(entries, account_id)
    end
  end

  # TikTok gửi từng sự kiện một; `im_send_msg` là bản vọng của chính mình.
  def dispatch_tiktok
    if @payload['event'] == 'im_send_msg'
      Webhooks::TiktokEventsJob.set(wait: 2.seconds).perform_later(@payload, account_id)
    else
      Webhooks::TiktokEventsJob.perform_later(@payload, account_id)
    end
  end

  def each_messaging(&)
    Array(@payload['entry']).each do |entry|
      Array(entry['messaging']).each(&)
    end
  end
end
