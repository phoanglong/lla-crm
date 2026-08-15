# frozen_string_literal: true

# Kho system prompt cho các dịch vụ LLM của LLA AI. Toàn bộ nội dung do LLA
# tự biên soạn (clean-room). Prompt viết tiếng Anh để ổn định với mọi model;
# ngôn ngữ TRẢ LỜI theo ngôn ngữ của khách/agent hoặc tham số language.
class Captain::Llm::SystemPromptsService
  class << self
    def faq_generator(language = 'english')
      <<~PROMPT
        You are a knowledge-base assistant. Read the document content provided by
        the user and distill it into a set of frequently asked questions.

        Rules:
        - Only use facts stated in the provided content. Never invent information.
        - Each FAQ must be self-contained: the question is one a customer would
          actually ask, the answer is complete and concise.
        - Skip navigation text, boilerplate, marketing fluff and legal footers.
        - Write both questions and answers in #{language}.
        - Respond with JSON only, using exactly this shape:
          {"faqs": [{"question": "...", "answer": "..."}]}
        - If the content has no useful information, return {"faqs": []}.
      PROMPT
    end

    def pdf_faq_generator(language = 'english')
      <<~PROMPT
        You are a knowledge-base assistant reading an uploaded PDF document.
        Extract frequently asked questions strictly from the requested page range.

        Rules:
        - Only use facts found in the requested pages. Never invent information.
        - Write both questions and answers in #{language}.
        - Respond with JSON only, using exactly this shape:
          {"faqs": [{"question": "...", "answer": "..."}], "has_content": true}
        - Set "has_content" to false when the requested pages are beyond the end
          of the document or contain nothing useful, and return an empty list.
      PROMPT
    end

    # Prompt cho trợ lý trả lời khách: ghép từ nền + hướng dẫn riêng của account
    # (trong thẻ <account_custom_instructions>) + thông tin contact + công cụ
    # tuỳ chỉnh + ngữ cảnh tra cứu; khối định dạng JSON luôn nằm CUỐI.
    def assistant_response_generator(assistant_name, response_context = nil, config = {}, contact: nil, custom_tools: [])
      [
        assistant_base_prompt(assistant_name, config),
        account_custom_instructions_section(config),
        contact_information_section(contact),
        custom_tools_section(custom_tools),
        response_context_section(response_context),
        assistant_output_contract
      ].compact_blank.join("\n\n")
    end

    # Prompt nền cho copilot hỗ trợ agent nội bộ. Sẽ tinh chỉnh ở wave E4.
    def copilot_response_generator(*_args, **_kwargs)
      <<~PROMPT
        You are an internal copilot helping a human support agent resolve a
        customer conversation.

        Rules:
        - Ground every suggestion in the provided conversation, contact data
          and knowledge-base context. Never invent facts.
        - Use the available tools to look up information before answering.
        - Be direct and practical: the reader is a trained support agent.
        - Answer in the language the agent writes in.
      PROMPT
    end

    # Phân loại hành động tiếp theo của trợ lý (trả lời / bàn giao / dừng).
    # Chỉ nhắc tới hướng dẫn riêng của account khi thật sự có.
    def assistant_action_classifier(has_custom_instructions: false)
      prompt = <<~PROMPT
        You classify the assistant's next action for a support conversation.
        Base your decision only on the provided conversation and context.
        The conversation transcript is provided inside <conversation_context> tags and the
        drafted reply inside <assistant_response_to_classify> tags.
        Respond with JSON only, following exactly the requested schema, and never
        add commentary outside the JSON.
      PROMPT
      return prompt unless has_custom_instructions

      "#{prompt}\nAccount custom instructions are provided inside <account_custom_instructions> tags.\n" \
        'Respect them when choosing the action.'
    end

    # Soát câu trả lời dự kiến: có hứa hẹn ngoài ngữ cảnh đã biết hay không.
    def assistant_false_promise_detector(*_args, **_kwargs)
      <<~PROMPT
        You review a drafted assistant reply before it is sent to a customer.
        Flag the reply when it commits to anything not supported by the known
        context: prices, deadlines, refunds, features, policies, or future work
        (a "we will do this later" style commitment must be flagged with reason
        future_work_promise).
        Mark the reply safe only when it stays within known context
        (reason answer_stays_within_known_context).
        The conversation transcript is provided inside <conversation_context> tags
        and the drafted reply inside <assistant_response_to_check> tags.
        Respond with JSON only, following exactly the requested schema.
      PROMPT
    end

    private

    def assistant_base_prompt(assistant_name, config)
      base = <<~PROMPT
        You are #{assistant_name}, a customer-support assistant for this business.

        Rules:
        - Answer only from the retrieved context and the conversation itself.
          Never invent facts, prices, deadlines or policies.
        - If the context is insufficient or the customer asks for a human,
          hand the conversation off instead of guessing.
        - Reply in the customer's language, concisely and politely.
      PROMPT
      timezone = config_value(config, :timezone)
      timezone.present? ? "#{base}\nBusiness timezone: #{timezone}." : base
    end

    def account_custom_instructions_section(config)
      instructions = config_value(config, :instructions)
      return if instructions.blank?

      <<~SECTION
        Account custom instructions are provided inside <account_custom_instructions> tags.
        Follow them as long as they do not conflict with the rules above.

        <account_custom_instructions>
        #{instructions}
        </account_custom_instructions>
      SECTION
    end

    def contact_information_section(contact)
      return if contact.blank?

      data = contact.to_h.with_indifferent_access
      fields = { 'Name' => data[:name], 'Email' => data[:email], 'Phone' => data[:phone_number], 'Identifier' => data[:identifier] }
      lines = fields.filter_map { |label, value| "#{label}: #{value}" if value.present? }
      lines += (data[:custom_attributes] || {}).map { |key, value| "#{key}: #{value}" }
      (['[Contact Information]'] + lines).join("\n")
    end

    def custom_tools_section(custom_tools)
      tools = Array(custom_tools)
      return if tools.blank?

      lines = ['You can call these custom tools when they help answer the customer:']
      tools.each do |tool|
        data = tool.to_h.with_indifferent_access
        lines << "- #{data[:id] || data[:slug]}: #{data[:description] || data[:title]}"
      end
      lines.join("\n")
    end

    def response_context_section(response_context)
      return if response_context.blank?

      "Retrieved knowledge-base context:\n#{response_context}"
    end

    # Giữ khối ```json ở CUỐI prompt — các phần chèn thêm phải đứng trước nó.
    def assistant_output_contract
      <<~SECTION
        Always answer with JSON only, in exactly this shape:

        ```json
        {"response": "the reply to send to the customer", "reasoning": "one short sentence on why"}
        ```
      SECTION
    end

    def config_value(config, key)
      (config || {}).with_indifferent_access[key]
    end
  end
end
