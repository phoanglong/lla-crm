# frozen_string_literal: true

# Tenant khai ứng dụng nền tảng **của chính mình**.
#
# Trả về `webhook_url` và `verify_token` để người vận hành dán sang màn hình của nền tảng.
# App secret thì chỉ đi một chiều: nhận vào, không bao giờ trả ra.
class Api::V1::Accounts::PlatformAppsController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?
  before_action :fetch_platform_app, only: [:show, :update, :destroy]

  def index
    render json: Current.account.lla_platform_apps.map { |app| serialize(app) }
  end

  def show
    render json: serialize(@platform_app)
  end

  def create
    platform_app = Current.account.lla_platform_apps.new(platform_app_params)
    platform_app.save!
    render json: serialize(platform_app), status: :created
  end

  def update
    # Secret rỗng nghĩa là "giữ nguyên cái đang có" — biểu mẫu không hiển thị lại secret nên
    # nếu ghi đè bằng rỗng thì mỗi lần sửa tên là một lần vô hiệu hoá kết nối.
    attributes = platform_app_params.to_h
    attributes.delete('app_secret') if attributes['app_secret'].blank?
    @platform_app.update!(attributes)
    render json: serialize(@platform_app)
  end

  def destroy
    @platform_app.destroy!
    head :no_content
  end

  private

  def fetch_platform_app
    @platform_app = Current.account.lla_platform_apps.find_by!(platform: params[:platform])
  end

  def serialize(app)
    {
      platform: app.platform,
      app_id: app.app_id,
      app_secret_configured: app.app_secret.present?,
      verify_token: app.verify_token,
      webhook_url: app.webhook_url,
      status: app.status,
      verified_at: app.verified_at,
      last_event_at: app.last_event_at,
      config: app.config
    }
  end

  def platform_app_params
    params.require(:platform_app).permit(:platform, :app_id, :app_secret, :status, config: {})
  end
end
