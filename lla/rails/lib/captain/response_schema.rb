# frozen_string_literal: true

# Cấu trúc phản hồi bắt buộc của trợ lý AI (ruby_llm-schema): câu trả lời gửi
# khách + lý do nội bộ để ghi vết/kiểm toán.
class Captain::ResponseSchema < RubyLLM::Schema
  string :response, description: 'Câu trả lời gửi cho khách hàng'
  string :reasoning, required: false, description: 'Giải thích ngắn vì sao trả lời như vậy'
end
