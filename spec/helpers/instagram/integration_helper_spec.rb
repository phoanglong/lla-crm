require 'rails_helper'

RSpec.describe Instagram::IntegrationHelper do
  include described_class

  # `state` nay ký bằng khoá của máy chủ chứ không bằng app secret của Instagram: mỗi tenant
  # mang ứng dụng riêng thì app secret mỗi nơi một khác, và lúc quay về từ Instagram thì
  # chưa biết tenant nào để chọn khoá giải mã.
  let(:signing_key) { Rails.application.key_generator.generate_key('instagram oauth state', 32) }

  describe '#generate_instagram_token' do
    let(:account_id) { 1 }
    let(:client_secret) { 'test_secret' }
    let(:current_time) { Time.current }

    before do
      allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_APP_SECRET', nil).and_return(client_secret)
      allow(Time).to receive(:current).and_return(current_time)
    end

    it 'generates a valid JWT token with correct payload' do
      token = generate_instagram_token(account_id)
      decoded_token = JWT.decode(token, signing_key, true, algorithm: 'HS256').first

      expect(decoded_token['sub']).to eq(account_id)
      expect(decoded_token['iat']).to eq(current_time.to_i)
    end

    context 'when the Instagram app secret is not configured' do
      let(:client_secret) { nil }

      # Không còn phụ thuộc app secret nữa: một tenant tự mang ứng dụng vẫn phải qua được
      # vòng OAuth kể cả khi bản cài đặt chưa khai ứng dụng nào.
      it 'still signs the state' do
        expect(generate_instagram_token(account_id)).to be_present
      end
    end

    context 'when an error occurs' do
      before do
        allow(JWT).to receive(:encode).and_raise(StandardError.new('Test error'))
      end

      it 'logs the error and returns nil' do
        expect(Rails.logger).to receive(:error).with('Failed to generate Instagram token: Test error')
        expect(generate_instagram_token(account_id)).to be_nil
      end
    end
  end

  describe '#token_payload' do
    let(:account_id) { 1 }
    let(:current_time) { Time.current }

    before do
      allow(Time).to receive(:current).and_return(current_time)
    end

    it 'returns a hash with the correct structure' do
      payload = token_payload(account_id)

      expect(payload).to be_a(Hash)
      expect(payload[:sub]).to eq(account_id)
      expect(payload[:iat]).to eq(current_time.to_i)
    end
  end

  describe '#verify_instagram_token' do
    let(:account_id) { 1 }
    let(:client_secret) { 'test_secret' }
    let(:valid_token) do
      JWT.encode({ sub: account_id, iat: Time.current.to_i }, signing_key, 'HS256')
    end

    before do
      allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_APP_SECRET', nil).and_return(client_secret)
    end

    it 'successfully verifies and returns account_id from valid token' do
      expect(verify_instagram_token(valid_token)).to eq(account_id)
    end

    context 'when token is blank' do
      it 'returns nil' do
        expect(verify_instagram_token('')).to be_nil
        expect(verify_instagram_token(nil)).to be_nil
      end
    end

    context 'when the token was signed with something else' do
      let(:valid_token) { JWT.encode({ sub: account_id }, 'khoa-khac', 'HS256') }

      it 'returns nil' do
        expect(verify_instagram_token(valid_token)).to be_nil
      end
    end

    context 'when token is invalid' do
      it 'logs the error and returns nil' do
        expect(Rails.logger).to receive(:error).with(/Unexpected error verifying Instagram token:/)
        expect(verify_instagram_token('invalid_token')).to be_nil
      end
    end
  end
end
