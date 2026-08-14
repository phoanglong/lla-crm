# frozen_string_literal: true

# Đồng bộ `users.provider` khi SAML của một tài khoản được bật hoặc tắt.
#
# Khi tắt, người dùng còn thuộc một tài khoản khác đang bật SAML thì PHẢI giữ
# nguyên provider 'saml' — nếu không họ mất đường đăng nhập vào tài khoản kia.
class Saml::UpdateAccountUsersProviderJob < ApplicationJob
  queue_as :low

  def perform(account_id, provider)
    account = Account.find(account_id)

    account.users.find_each do |user|
      next if provider == 'email' && saml_enabled_elsewhere?(user, account)

      # Bỏ qua validation: đây là thao tác quản trị trên một cột duy nhất, không
      # được để mật khẩu/2FA của bản ghi cũ chặn việc đổi provider.
      user.update_column(:provider, provider) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  private

  def saml_enabled_elsewhere?(user, account)
    other_account_ids = user.account_users.where.not(account_id: account.id).select(:account_id)

    AccountSamlSettings.exists?(account_id: other_account_ids)
  end
end
