# frozen_string_literal: true

# Kiểm chữ ký webhook bằng secret **của tenant** sở hữu ứng dụng.
#
# Meta (Facebook, Instagram, WhatsApp) ký `X-Hub-Signature-256: sha256=<hmac_sha256(secret, body)>`.
# TikTok ký `X-Tiktok-Signature`/`t=…,s=…` trên `t + '.' + body`. Cả hai đều so sánh trong
# thời gian không phụ thuộc nội dung.
class Lla::Platform::SignatureVerifier
  META_HEADER = 'X-Hub-Signature-256'
  META_PREFIX = 'sha256='
  TIKTOK_HEADER = 'X-Tiktok-Signature'
  # Chữ ký TikTok ký kèm dấu thời gian; quá cửa sổ này thì một yêu cầu bắt được vẫn phát lại được.
  TIKTOK_MAX_SKEW = 5.minutes

  def initialize(platform_app, request)
    @app = platform_app
    @request = request
  end

  def valid?
    secret = @app.app_secret.to_s
    return false if secret.blank?

    case @app.platform
    when 'facebook', 'instagram', 'whatsapp' then valid_meta?(secret)
    when 'tiktok' then valid_tiktok?(secret)
    else false
    end
  end

  private

  def body
    @body ||= @request.raw_post
  end

  def valid_meta?(secret)
    signature = @request.headers[META_HEADER].to_s
    return false unless signature.start_with?(META_PREFIX)

    expected = META_PREFIX + OpenSSL::HMAC.hexdigest('SHA256', secret, body)
    ActiveSupport::SecurityUtils.secure_compare(expected, signature)
  end

  def valid_tiktok?(secret)
    parts = @request.headers[TIKTOK_HEADER].to_s.split(',').to_h { |pair| pair.split('=', 2) }
    timestamp = parts['t'].to_s
    signature = parts['s'].to_s
    return false if timestamp.blank? || signature.blank?
    return false if (Time.now.to_i - timestamp.to_i).abs > TIKTOK_MAX_SKEW.to_i

    expected = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{body}")
    ActiveSupport::SecurityUtils.secure_compare(expected, signature)
  end
end
