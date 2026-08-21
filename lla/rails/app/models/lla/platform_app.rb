# frozen_string_literal: true

# Ứng dụng nền tảng (Meta app, TikTok app, Zalo app…) **của một tenant**.
#
# Điểm khác biệt duy nhất nhưng quyết định so với cách cũ: vì ứng dụng thuộc về tenant, tenant
# đăng ký được một URL webhook của riêng mình. `webhook_token` chính là URL đó, nên nó vừa là
# định tuyến ("tin này của ai") vừa là lớp xác thực thứ nhất ("ai biết được đường này").
class Lla::PlatformApp < ApplicationRecord
  self.table_name = 'lla_platform_apps'

  # Danh sách mở dần theo từng nền tảng được đấu dây thật. Khai một nền tảng chưa có đường
  # xử lý thì tenant sẽ có một URL webhook nuốt tin trong im lặng — thà không cho tạo.
  PLATFORMS = %w[facebook].freeze
  STATUSES = %w[pending active disabled error].freeze
  WEBHOOK_TOKEN_BYTES = 24

  belongs_to :account, class_name: '::Account'

  encrypts :app_secret if Chatwoot.encryption_configured?

  before_validation :ensure_tokens, on: :create

  validates :platform, presence: true, inclusion: { in: PLATFORMS }
  validates :app_id, presence: true, length: { maximum: 128 }
  validates :status, inclusion: { in: STATUSES }
  validates :platform, uniqueness: { scope: :account_id }
  validates :webhook_token, presence: true, length: { minimum: 24, maximum: 64 }
  validate :require_encryption_for_secret

  scope :active, -> { where(status: 'active') }

  # Đường webhook của tenant. Một khuôn cho mọi nền tảng, để thêm nền tảng mới không phải
  # nghĩ lại chuyện định tuyến.
  def webhook_url
    "#{self.class.base_url}/webhooks/tenant/#{platform}/#{webhook_token}"
  end

  def self.base_url
    ENV.fetch('FRONTEND_URL', '').to_s.chomp('/')
  end

  # Tra bằng token là đường đi duy nhất từ một yêu cầu HTTP về đúng tenant. Token ngắn hơn
  # mức tối thiểu thì thậm chí không truy vấn — chuỗi rác không đáng một vòng tới CSDL.
  def self.for_webhook_token(token)
    token = token.to_s
    return if token.length < 24

    find_by(webhook_token: token)
  end

  # Chỉ là dấu thời gian cho bảng kiểm tra, chạy trên mỗi sự kiện đến — không đáng một
  # vòng validation, và cũng không có gì để validate.
  def record_event!
    update_columns(last_event_at: Time.current, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  private

  def ensure_tokens
    self.webhook_token = SecureRandom.hex(WEBHOOK_TOKEN_BYTES) if webhook_token.blank?
    # Verify token là thứ tenant phải dán sang màn hình của nền tảng; sinh sẵn thì không ai
    # phải nghĩ ra một chuỗi ngẫu nhiên "đủ khó".
    self.verify_token = SecureRandom.hex(16) if verify_token.blank?
  end

  # Không có khoá mã hoá thì `app_secret` sẽ nằm plaintext trong CSDL. Với secret của **khách**
  # thì đó không phải là một sự đánh đổi được phép âm thầm chấp nhận.
  def require_encryption_for_secret
    return if app_secret.blank? || Chatwoot.encryption_configured?

    errors.add(:app_secret, 'requires Active Record encryption keys')
  end
end
