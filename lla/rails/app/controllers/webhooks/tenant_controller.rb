# frozen_string_literal: true

# Webhook của **tenant**, không phải của bản cài đặt.
#
# Đường cũ (`/bot`, `/webhooks/instagram`, `/webhooks/tiktok`) là một cửa chung cho mọi khách:
# một verify token, một app secret, và tenant nhận tin được đoán ra từ `page_id` toàn cục.
# Ở đây token trong đường dẫn **là** danh tính: nó chỉ ra đúng một `Lla::PlatformApp`, và từ
# đó có tài khoản, verify token và app secret của chính tenant ấy.
#
# Đường cũ vẫn giữ nguyên cho các tenant dùng ứng dụng của LLA.
class Webhooks::TenantController < ActionController::API
  before_action :load_platform_app
  before_action :verify_signature!, only: :events

  # Nền tảng gọi GET một lần khi người dùng lưu URL webhook. Trả lại `hub.challenge` khi và
  # chỉ khi verify token khớp bản ghi của tenant.
  def verify
    if ActiveSupport::SecurityUtils.secure_compare(
      params['hub.verify_token'].to_s, @platform_app.verify_token.to_s
    )
      render plain: params['hub.challenge'].to_s
    else
      render status: :unauthorized, json: { error: 'wrong verify token' }
    end
  end

  def events
    @platform_app.record_event!
    Lla::Platform::EventDispatcher.new(@platform_app, params.to_unsafe_hash).call
    render json: { ok: true }
  end

  private

  def load_platform_app
    @platform_app = Lla::PlatformApp.for_webhook_token(params[:webhook_token])
    head :not_found if @platform_app.blank? || @platform_app.platform != params[:platform]
  end

  # Chữ ký ký bằng app secret **của tenant**. Không có secret thì từ chối: một webhook không
  # xác thực được là một cửa mở cho bất kỳ ai biết đường dẫn.
  def verify_signature!
    return if Lla::Platform::SignatureVerifier.new(@platform_app, request).valid?

    Rails.logger.warn("Tenant webhook signature rejected: app=#{@platform_app.id}")
    head :unauthorized
  end
end
