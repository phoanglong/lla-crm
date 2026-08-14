require 'rails_helper'

RSpec.describe 'Super Admin Application Config API', type: :request do
  let(:super_admin) { create(:super_admin) }

  describe 'GET /super_admin/app_config' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        get '/super_admin/app_config'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      let!(:config) { create(:installation_config, { name: 'FB_APP_ID', value: 'TESTVALUE' }) }

      it 'shows the app_config page' do
        sign_in(super_admin, scope: :super_admin)
        get '/super_admin/app_config?config=facebook'
        expect(response).to have_http_status(:success)
        expect(response.body).to include(config.value)
      end

      it 'does not render saved secret values in the page' do
        secret = create(:installation_config, { name: 'FB_APP_SECRET', value: 'must-not-appear-in-html' })

        sign_in(super_admin, scope: :super_admin)
        get '/super_admin/app_config?config=facebook'

        expect(response).to have_http_status(:success)
        expect(response.body).not_to include(secret.value)
        expect(response.body).to include('Đã cấu hình — để trống để giữ nguyên')
      end
    end
  end

  describe 'POST /super_admin/app_config' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        post '/super_admin/app_config', params: { app_config: { TESTKEY: 'TESTVALUE' } }
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an aunthenticated super admin' do
      it 'shows the app_config page' do
        sign_in(super_admin, scope: :super_admin)
        post '/super_admin/app_config?config=facebook', params: { app_config: { FB_APP_ID: 'FB_APP_ID' } }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(super_admin_settings_path)
        expect(flash[:notice]).to be_present
        expect(flash[:alert]).to be_blank
        expect(flash[:success]).to be_blank

        config = GlobalConfig.get('FB_APP_ID')
        expect(config['FB_APP_ID']).to eq('FB_APP_ID')
      end

      it 'asks admins to restart web and worker processes for runtime config changes' do
        sign_in(super_admin, scope: :super_admin)
        post '/super_admin/app_config?config=captain', params: { app_config: { CAPTAIN_OPEN_AI_ENDPOINT: 'https://api.openai.com' } }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(super_admin_settings_path)
        expect(flash[:success]).to be_present
        expect(flash[:alert]).to be_blank
        expect(flash[:notice]).to be_blank
      end

      it 'preserves a configured secret when the submitted secret field is blank' do
        config = create(:installation_config, { name: 'FB_APP_SECRET', value: 'existing-secret' })
        sign_in(super_admin, scope: :super_admin)

        post '/super_admin/app_config?config=facebook', params: { app_config: { FB_APP_SECRET: '' } }

        expect(response).to have_http_status(:found)
        expect(config.reload.value).to eq('existing-secret')
      end

      it 'updates the Zalo bridge URL used by onboarding' do
        sign_in(super_admin, scope: :super_admin)

        post '/super_admin/app_config?config=zalo', params: { app_config: { ZALO_BRIDGE_URL: 'https://zbridge.example.com' } }

        expect(response).to have_http_status(:found)
        expect(GlobalConfig.get_value('ZALO_BRIDGE_URL')).to eq('https://zbridge.example.com')
      end
    end
  end
end
