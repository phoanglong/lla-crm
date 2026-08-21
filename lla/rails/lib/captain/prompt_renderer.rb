# frozen_string_literal: true

# Render prompt liquid cho trợ lý AI. Template do LLA tự biên soạn, đặt tại
# lla/rails/lib/captain/prompts (KHÔNG dùng nội dung enterprise/ — clean-room);
# snippet dùng lại qua thẻ {% render %} đọc từ thư mục snippets.
module Captain::PromptRenderer
  TEMPLATE_DIR = 'lla/rails/lib/captain/prompts'

  # Nạp snippet cho thẻ {% render 'ten_snippet' %} của Liquid.
  class SnippetFileSystem
    def read_template_file(template_path)
      path = Rails.root.join(TEMPLATE_DIR, 'snippets', "#{template_path}.liquid").to_s
      raise Liquid::FileSystemError, "No such snippet: #{template_path}" unless File.exist?(path)

      File.read(path)
    end
  end

  class << self
    def render(template_name, context)
      template = Liquid::Template.parse(load_template(template_name))
      template.render(stringify_keys(context), registers: { file_system: SnippetFileSystem.new })
    end

    private

    def load_template(template_name)
      path = Rails.root.join(TEMPLATE_DIR, "#{template_name}.liquid")
      raise "Template not found: #{template_name}" unless File.exist?(path)

      File.read(path)
    end

    def stringify_keys(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify_keys(v) }
      when Array then value.map { |item| stringify_keys(item) }
      else value
      end
    end
  end
end
