require 'rails_helper'

RSpec.describe 'Installation::Onboarding API', type: :request do
  let(:super_admin) { create(:super_admin) }

  describe 'GET /installation/onboarding' do
    context 'when CHATWOOT_INSTALLATION_ONBOARDING redis key is not set' do
      it 'redirects back' do
        expect(Redis::Alfred.get(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)).to be_nil
        get '/installation/onboarding'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when CHATWOOT_INSTALLATION_ONBOARDING redis key is set' do
      it 'returns onboarding page' do
        Redis::Alfred.set(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING, true)
        get '/installation/onboarding'
        expect(response).to have_http_status(:success)
        Redis::Alfred.delete(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)
      end
    end
  end

  describe 'POST /installation/onboarding' do
    let(:account_builder) { double }

    before do
      allow(AccountBuilder).to receive(:new).and_return(account_builder)
      allow(account_builder).to receive(:perform).and_return(true)
      Redis::Alfred.set(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING, true)
    end

    after do
      Redis::Alfred.delete(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)
    end

    context 'when onboarding successfull' do
      it 'deletes the redis key' do
        post '/installation/onboarding', params: { user: {} }
        expect(Redis::Alfred.get(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)).to be_nil
      end

      # Finishing onboarding used to post the owner's company name, name and email
      # address to Chatwoot's hosted hub. There is no longer anything to opt into,
      # so the parameter is not permitted and the form does not offer it.
      it 'ignores subscribe_to_updates and makes no outbound request' do
        # WebMock refuses every non-local connection, so a redirect here is proof
        # that nothing was posted anywhere.
        post '/installation/onboarding', params: { user: {}, subscribe_to_updates: 1 }

        expect(response).to have_http_status(:redirect)
        expect(Redis::Alfred.get(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)).to be_nil
      end

      it 'does not offer a subscription checkbox on the form' do
        get '/installation/onboarding'

        expect(response.body).not_to include('subscribe_to_updates')
      end
    end

    context 'when onboarding is not successfull' do
      it 'does not deletes the redis key' do
        allow(AccountBuilder).to receive(:new).and_raise('error')
        post '/installation/onboarding', params: { user: {} }
        expect(Redis::Alfred.get(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)).not_to be_nil
      end
    end
  end
end
