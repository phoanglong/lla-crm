# frozen_string_literal: true

# Nhà cung cấp AI thuộc về tenant, không thuộc về bản cài đặt.
#
# Cho tới nay mọi lệnh gọi LLM đều đi qua đúng một khoá và một endpoint đọc từ
# `InstallationConfig`, cấu hình một lần cho cả tiến trình. Tenant chỉ đổi được **tên mô hình**;
# nhà cung cấp, endpoint và khoá thì không. Muốn dùng Anthropic, Gemini, Azure, OpenRouter hay
# một máy chủ tự dựng thì cả bản cài đặt phải đổi cùng nhau — nghĩa là không tenant nào đổi được.
#
# Bảng này cho mỗi tenant khai nhà cung cấp của chính họ, khoá của chính họ. Khoá của LLA vẫn
# còn đó làm lựa chọn mặc định cho ai không muốn tự lo.
class CreateLlaAiProviders < ActiveRecord::Migration[7.1]
  def up
    create_providers
    add_provider_indexes
    add_provider_constraints
  end

  def down
    drop_table :lla_ai_providers, if_exists: true
  end

  private

  def create_providers
    create_table :lla_ai_providers do |t|
      t.bigint :account_id, null: false
      t.string :kind, null: false, limit: 32
      t.string :name, null: false, limit: 64
      t.string :api_base, limit: 512
      # Mã hoá ở tầng ứng dụng (Active Record encryption).
      t.text :api_key
      t.jsonb :config, null: false, default: {}
      t.boolean :enabled, null: false, default: true
      t.datetime :verified_at
      t.string :last_error, limit: 512
      t.timestamps
    end
  end

  def add_provider_indexes
    # Tên là thứ người dùng gõ trong `<tên>/<mô hình>`, nên phải duy nhất trong một tenant.
    add_index :lla_ai_providers, %i[account_id name], unique: true, name: 'idx_lla_ai_providers_tenant_name'
    add_index :lla_ai_providers, %i[account_id enabled], name: 'idx_lla_ai_providers_tenant_enabled'
    add_foreign_key :lla_ai_providers, :accounts, on_delete: :cascade
  end

  def add_provider_constraints
    add_check_constraint :lla_ai_providers,
                         "kind IN ('openai','anthropic','gemini','azure_openai','openai_compatible')",
                         name: 'chk_lla_ai_providers_kind'
    # Tên đi vào định danh mô hình nên không được chứa dấu `/`, và không được rỗng.
    add_check_constraint :lla_ai_providers,
                         "name ~ '^[a-z0-9][a-z0-9_-]{0,63}$'",
                         name: 'chk_lla_ai_providers_name_format'
  end
end
