require 'rails_helper'

RSpec.describe 'Super Admin API documentation', type: :request do
  let(:super_admin) { create(:super_admin) }

  describe 'GET /super_admin/api_docs' do
    it 'requires super admin authentication' do
      get '/super_admin/api_docs'

      expect(response).to have_http_status(:redirect)
    end

    it 'renders the LLA CRM OpenAPI viewer inside the super admin shell' do
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/api_docs'

      expect(response).to have_http_status(:success)
      expect(response.body).to include('API &amp; Swagger', 'data-api-docs', schema_super_admin_api_docs_path)
      expect(response.body).to include('Trung tâm quản trị')
      expect(response.body).not_to include('cdn.jsdelivr.net')
    end
  end

  describe 'GET /super_admin/api_docs/schema' do
    it 'serves the OpenAPI document only to authenticated super admins' do
      get '/super_admin/api_docs/schema'
      expect(response).to have_http_status(:redirect)

      sign_in(super_admin, scope: :super_admin)
      get '/super_admin/api_docs/schema'

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.dig('info', 'title')).to eq('LLA CRM API')
      expect(response.headers['Cache-Control']).to include('no-store')
    end
  end
end
