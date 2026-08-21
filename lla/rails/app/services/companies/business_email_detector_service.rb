# frozen_string_literal: true

# Email này có phải email doanh nghiệp không: hợp lệ, không phải domain dùng một
# lần, và không thuộc nhà cung cấp email miễn phí (gem email-provider-info).
class Companies::BusinessEmailDetectorService
  def initialize(email)
    @email = email
  end

  def perform
    return false if @email.blank?

    address = ValidEmail2::Address.new(@email)
    return false unless address.valid?
    return false if address.disposable_domain?

    EmailProviderInfo.call(@email).nil?
  end
end
