require 'rails_helper'

RSpec.describe 'API Base', type: :request do
  describe 'request to api base url' do
    it 'returns api version' do
      get '/api/'
      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include(
        'product' => 'LLA CRM',
        'version' => Rails.root.join('VERSION_LLA').read.strip,
        'compatibility_product' => 'Chatwoot',
        'compatibility_version' => Rails.root.join('VERSION_CW').read.strip,
        'queue_services' => 'ok',
        'data_services' => 'ok'
      )
    end
  end
end
