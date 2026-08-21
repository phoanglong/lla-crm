# frozen_string_literal: true

# Ứng dụng nền tảng thuộc về tenant, không thuộc về bản cài đặt.
#
# Cho tới nay Facebook/Instagram/TikTok/WhatsApp-embedded đều dùng **một** ứng dụng của LLA:
# một `FB_APP_SECRET`, một verify token, một endpoint webhook chung, và tin đến được đoán về
# đúng tenant bằng `page_id`/`business_id` toàn cục. Mô hình đó không phải SaaS — nó là
# "LLA sở hữu tài khoản, khách dùng nhờ".
#
# Bảng này lật lại: mỗi tenant khai ứng dụng của chính họ. Vì ứng dụng là của họ, họ đăng ký
# được một **URL webhook riêng** (`webhook_token` nằm trong đường dẫn), nên định tuyến, verify
# token và chữ ký đều quy về một bản ghi thay vì ba biến môi trường dùng chung.
class CreateLlaPlatformApps < ActiveRecord::Migration[7.1]
  def up
    create_platform_apps
    add_platform_app_indexes
    add_platform_app_constraints
  end

  def down
    drop_table :lla_platform_apps, if_exists: true
  end

  private

  def create_platform_apps
    create_table :lla_platform_apps do |t|
      t.bigint :account_id, null: false
      t.string :platform, null: false, limit: 32
      t.string :app_id, null: false, limit: 128
      # Mã hoá ở tầng ứng dụng (Active Record encryption), nên cột là text.
      t.text :app_secret
      t.string :verify_token, limit: 128
      t.string :webhook_token, null: false, limit: 64
      t.jsonb :config, null: false, default: {}
      t.string :status, null: false, limit: 32, default: 'pending'
      t.datetime :verified_at
      t.datetime :last_event_at
      t.string :last_error, limit: 512
      t.timestamps
    end
  end

  def add_platform_app_indexes
    # Một tenant có đúng một ứng dụng cho mỗi nền tảng: hai ứng dụng cùng nền tảng trong một
    # tenant thì không có cách nào chọn đúng cái nào khi ký/kiểm chữ ký.
    add_index :lla_platform_apps, %i[account_id platform], unique: true,
                                                           name: 'idx_lla_platform_apps_tenant_platform'
    # Token là địa chỉ webhook — phải duy nhất trên toàn hệ thống, và tra được một lần.
    add_index :lla_platform_apps, :webhook_token, unique: true, name: 'idx_lla_platform_apps_webhook_token'
    add_index :lla_platform_apps, %i[platform app_id], name: 'idx_lla_platform_apps_platform_app'

    add_foreign_key :lla_platform_apps, :accounts, on_delete: :cascade
  end

  def add_platform_app_constraints
    add_check_constraint :lla_platform_apps,
                         "platform IN ('facebook','instagram','whatsapp','tiktok')",
                         name: 'chk_lla_platform_apps_platform'
    add_check_constraint :lla_platform_apps,
                         "status IN ('pending','active','disabled','error')",
                         name: 'chk_lla_platform_apps_status'
    add_check_constraint :lla_platform_apps,
                         'char_length(webhook_token) >= 24',
                         name: 'chk_lla_platform_apps_webhook_token_length'
  end
end
