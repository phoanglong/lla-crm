require 'rails_helper'

RSpec.describe Lla::PlatformApp do
  # Không có khoá mã hoá thì model từ chối giữ secret của khách — đó là hành vi đúng, nên các
  # ví dụ cần secret chỉ chạy ở bộ có bật mã hoá.
  def skip_without_encryption
    skip('encryption keys missing; credential examples run in the encryption-enabled suite') unless Chatwoot.encryption_configured?
  end

  let(:account) { create(:account) }

  it 'issues its own webhook token and verify token so nobody has to invent one' do
    skip_without_encryption
    app = described_class.create!(account: account, platform: 'facebook', app_id: '123456789', app_secret: 'app-secret')

    aggregate_failures do
      expect(app.webhook_token.length).to be >= 48
      expect(app.verify_token).to be_present
      expect(app.webhook_url).to end_with("/webhooks/tenant/facebook/#{app.webhook_token}")
    end
  end

  it 'gives one tenant one app per platform' do
    skip_without_encryption
    described_class.create!(account: account, platform: 'facebook', app_id: '1', app_secret: 's')

    expect do
      described_class.create!(account: account, platform: 'facebook', app_id: '2', app_secret: 's')
    end.to raise_error(ActiveRecord::RecordInvalid)
  end

  # Đây là secret của KHÁCH. Nằm plaintext trong CSDL là một sự đánh đổi không được phép
  # xảy ra trong im lặng.
  it 'stores the app secret encrypted, not as readable text' do
    skip_without_encryption

    app = described_class.create!(account: account, platform: 'facebook', app_id: '123', app_secret: 'khong-duoc-doc-duoc')
    raw = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql(['SELECT app_secret FROM lla_platform_apps WHERE id = ?', app.id])
    )

    aggregate_failures do
      expect(raw).not_to include('khong-duoc-doc-duoc')
      expect(app.reload.app_secret).to eq('khong-duoc-doc-duoc')
    end
  end

  it 'refuses to hold a customer secret when encryption is not configured' do
    allow(Chatwoot).to receive(:encryption_configured?).and_return(false)

    app = described_class.new(account: account, platform: 'facebook', app_id: '123', app_secret: 'plaintext')

    expect(app).not_to be_valid
    expect(app.errors[:app_secret]).to be_present
  end

  it 'refuses a platform that has no wired dispatch path' do
    skip_without_encryption
    app = described_class.new(account: account, platform: 'whatsapp', app_id: '123', app_secret: 's')

    expect(app).not_to be_valid
  end

  it 'does not go to the database for a token too short to be one' do
    expect(described_class).not_to receive(:find_by)

    expect(described_class.for_webhook_token('short')).to be_nil
  end
end
