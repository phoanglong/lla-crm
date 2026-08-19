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

    # The check used to be `ActiveRecord::Base.connection.active?`, which answers
    # "has this thread already connected", not "is PostgreSQL reachable". Active
    # Record connects lazily and this action skips authentication, so on a freshly
    # started process nothing had touched the database yet and a healthy stack
    # reported `data_services: failing`. Under test the answer was always "ok",
    # because the transactional fixture had opened a connection before the request
    # — the assertion above passed for a reason unrelated to what it claims.
    it 'reports the database by asking it, not by asking whether this thread happens to be connected' do
      allow(ActiveRecord::Base.connection).to receive(:active?).and_return(false)

      get '/api/'

      expect(response.parsed_body['data_services']).to eq('ok')
    end

    it 'reports failing when the database will not answer' do
      allow(ActiveRecord::Base.connection).to receive(:select_value)
        .with('SELECT 1').and_raise(ActiveRecord::ConnectionNotEstablished)

      get '/api/'

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['data_services']).to eq('failing')
    end

    # An unauthenticated endpoint that opens a Redis connection per call and never
    # closes it hands anyone who can reach it a socket-exhaustion primitive.
    it 'checks Redis over the existing pool instead of opening a connection per request' do
      expect(Redis).not_to receive(:new)

      get '/api/'

      expect(response.parsed_body['queue_services']).to eq('ok')
    end

    it 'reports failing when Redis will not answer' do
      allow(Redis::Alfred).to receive(:with).and_raise(Redis::CannotConnectError)

      get '/api/'

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['queue_services']).to eq('failing')
    end
  end
end
