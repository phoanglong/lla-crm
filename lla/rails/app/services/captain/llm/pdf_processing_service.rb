# frozen_string_literal: true

# Đưa file PDF của tài liệu lên OpenAI Files để sinh FAQ theo trang.
# Idempotent: đã có openai_file_id thì bỏ qua.
class Captain::Llm::PdfProcessingService
  def initialize(document)
    @document = document
  end

  def process
    return if @document.openai_file_id.present?

    file_id = upload_pdf
    raise CustomExceptions::Pdf::UploadError, I18n.t('captain.documents.pdf_upload_failed') if file_id.blank?

    @document.store_openai_file_id(file_id)
  end

  private

  def upload_pdf
    @document.pdf_file.blob.open do |file|
      response = client.files.upload(parameters: { file: file, purpose: 'user_data' })
      response['id']
    end
  end

  def client
    @client ||= OpenAI::Client.new(access_token: InstallationConfig.find_by!(name: 'CAPTAIN_OPEN_AI_API_KEY').value)
  end
end
