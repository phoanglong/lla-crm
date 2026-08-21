require 'rails_helper'

RSpec.describe 'LLA SAML omniauth callbacks', type: :request do
  let!(:account) { create(:account) }
  let!(:member) { create(:user, email: 'saml.user@example.com', account: account) }
  let(:outsider_account) { create(:account) }

  before do
    create(:account_saml_settings, account: account)
    OmniAuth.config.test_mode = true
    # full_host được chốt lúc boot (config/initializers/omniauth.rb) từ
    # FRONTEND_URL; trong test phải trỏ về cùng host với phiên request, nếu không
    # cookie phiên bị rơi giữa chừng và omniauth.params không về tới callback.
    OmniAuth.config.full_host = 'http://www.example.com'
  end

  after do
    OmniAuth.config.mock_auth[:saml] = nil
    OmniAuth.config.test_mode = false
    # Trả về đúng giá trị initializer đã chốt lúc boot.
    OmniAuth.config.full_host = ENV.fetch('FRONTEND_URL', 'http://localhost:3000')
  end

  def mock_saml_auth(email)
    OmniAuth.config.mock_auth[:saml] = OmniAuth::AuthHash.new(
      provider: 'saml',
      uid: email,
      info: { email: email, name: 'SAML User', first_name: 'SAML' },
      extra: { raw_info: { 'groups' => [] } }
    )
  end

  # Đi đủ ba bước như production: khởi tạo /auth/saml?account_id=… (OmniAuth giữ
  # account_id qua phiên) → callback → redirect_callbacks của devise_token_auth
  # → omniauth_success.
  def perform_saml_flow(account_id)
    post "/auth/saml?account_id=#{account_id}"
    follow_redirect! while response.location&.exclude?('/app/login')
  end

  describe 'SAML omniauth flow' do
    context 'when the user belongs to the account' do
      it 'signs the user in with an sso auth token' do
        with_modified_env FRONTEND_URL: 'http://www.example.com' do
          mock_saml_auth(member.email)

          perform_saml_flow(account.id)

          expect(response.location).to match(%r{/app/login\?email=.+&sso_auth_token=.+})
          expect(member.reload.provider).to eq('saml')
        end
      end
    end

    context 'when the user belongs to a different account' do
      let!(:outsider) { create(:user, email: 'outsider@example.com', account: outsider_account) }

      it 'refuses and redirects to the SSO login page with an error' do
        with_modified_env FRONTEND_URL: 'http://www.example.com' do
          mock_saml_auth(outsider.email)

          perform_saml_flow(account.id)

          expect(response.location).to eq('http://www.example.com/app/login?error=saml-authentication-failed')
          expect(outsider.reload.provider).not_to eq('saml')
        end
      end
    end
  end
end
