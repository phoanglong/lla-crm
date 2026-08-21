require 'rails_helper'

# `provider_config` giữ khoá của KHÁCH. Nằm plaintext trong CSDL nghĩa là ai đọc được một bản
# sao lưu là đọc được khoá WhatsApp, khoá Bandwidth và token hộp thư của mọi tenant.
RSpec.describe Lla::EncryptedProviderConfig do
  def skip_without_encryption
    skip('encryption keys missing; credential examples run in the encryption-enabled suite') unless Chatwoot.encryption_configured?
  end

  def raw_provider_config(table, id)
    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql(["SELECT provider_config::text FROM #{table} WHERE id = ?", id])
    ).to_s
  end

  let(:account) { create(:account) }

  describe 'WhatsApp' do
    let(:channel) do
      create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false,
                                provider_config: { 'api_key' => 'khoa-cua-khach', 'phone_number_id' => '112233',
                                                   'business_account_id' => 'waba-1' })
    end

    it 'keeps the customer key out of the database, and still hands it back in Ruby' do
      skip_without_encryption

      aggregate_failures do
        expect(raw_provider_config('channel_whatsapp', channel.id)).not_to include('khoa-cua-khach')
        expect(channel.reload.provider_config['api_key']).to eq('khoa-cua-khach')
      end
    end

    # Định tuyến vẫn phải truy vấn được bằng `->>`; mã hoá cả cột là mất chỗ này.
    it 'leaves the routing keys queryable in SQL' do
      skip_without_encryption
      channel

      aggregate_failures do
        expect(raw_provider_config('channel_whatsapp', channel.id)).to include('112233')
        expect(Channel::Whatsapp.where("provider_config->>'business_account_id' = ?", 'waba-1')).to include(channel)
      end
    end

    it 'does not report a change when nothing was edited' do
      skip_without_encryption
      reloaded = Channel::Whatsapp.find(channel.id)

      expect(reloaded).not_to be_changed
    end

    # Hàng đã có từ trước khi bật mã hoá vẫn phải đọc được, nếu không thì bật mã hoá là làm
    # gãy mọi hộp thư đang chạy.
    it 'still reads a row that was written before encryption' do
      skip_without_encryption
      channel
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql(
          ["UPDATE channel_whatsapp SET provider_config = ?::jsonb WHERE id = ?", { 'api_key' => 'chua-ma-hoa' }.to_json, channel.id]
        )
      )

      expect(Channel::Whatsapp.find(channel.id).provider_config['api_key']).to eq('chua-ma-hoa')
    end

    it 'encrypts a secret written in place, not only one assigned wholesale' do
      skip_without_encryption
      reloaded = Channel::Whatsapp.find(channel.id)
      reloaded.define_singleton_method(:validate_provider_config) { nil }
      reloaded.provider_config['api_key'] = 'khoa-moi'
      reloaded.save!

      aggregate_failures do
        expect(raw_provider_config('channel_whatsapp', reloaded.id)).not_to include('khoa-moi')
        expect(reloaded.reload.provider_config['api_key']).to eq('khoa-moi')
      end
    end
  end

  describe 'SMS' do
    let(:channel) do
      create(:channel_sms, account: account,
                           provider_config: { 'api_key' => 'bandwidth-key', 'api_secret' => 'bandwidth-secret', 'application_id' => 'app-1' })
    end

    it 'keeps the Bandwidth credentials out of the database' do
      skip_without_encryption

      raw = raw_provider_config('channel_sms', channel.id)

      aggregate_failures do
        expect(raw).not_to include('bandwidth-key')
        expect(raw).not_to include('bandwidth-secret')
        expect(raw).to include('app-1')
        expect(channel.reload.provider_config.values_at('api_key', 'api_secret')).to eq(%w[bandwidth-key bandwidth-secret])
      end
    end
  end

  describe 'Email' do
    let(:channel) do
      create(:channel_email, account: account,
                             provider_config: { 'access_token' => 'token-hop-thu', 'refresh_token' => 'refresh-hop-thu',
                                                'expires_on' => '2026-01-01 00:00:00 UTC' })
    end

    it 'keeps the mailbox OAuth tokens out of the database' do
      skip_without_encryption

      raw = raw_provider_config('channel_email', channel.id)

      aggregate_failures do
        expect(raw).not_to include('token-hop-thu')
        expect(raw).not_to include('refresh-hop-thu')
        expect(raw).to include('2026-01-01')
        expect(channel.reload.provider_config['access_token']).to eq('token-hop-thu')
      end
    end

    # Các dịch vụ làm mới token gán hash khoá Symbol; mã hoá phải nhận ra chúng.
    it 'encrypts symbol-keyed values too, because that is how the refresh services write them' do
      skip_without_encryption
      channel.update!(provider_config: { access_token: 'token-symbol', refresh_token: 'refresh-symbol', expires_on: 'x' })

      aggregate_failures do
        expect(raw_provider_config('channel_email', channel.id)).not_to include('token-symbol')
        expect(channel.reload.provider_config['access_token']).to eq('token-symbol')
      end
    end
  end
end
