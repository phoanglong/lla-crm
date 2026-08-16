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
    def assistant_response_generator(assistant_name, product_name, config = {}, **context)
      [
        assistant_identity_section(assistant_name, product_name),
        current_time_section(config),
        assistant_response_guidelines(config),
        account_custom_instructions_section(config),
        contact_information_section(context[:contact]),
        custom_tools_section(context.fetch(:custom_tools, [])),
        response_context_section(context[:response_context]),
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
        You are a routing classifier for a customer-support assistant.

        Choose "continue" when the assistant can answer a general question, give a
        bounded answer, ask one useful clarification, collect a missing identifier,
        or point to an approved external contact path.

        Choose "handoff" when the user explicitly asks for a human, accepts a human
        offer, needs private account/transaction verification, repeats an unresolved
        operational issue, is stuck in a frustration loop, or the drafted response
        claims the conversation will be transferred now.

        action MUST be one of: #{Captain::AssistantActionSchema::ACTIONS.join(', ')}.
        action_reason MUST be one of:
        #{Captain::AssistantActionSchema::REASONS.join("\n")}

        The transcript is inside <conversation_context> and the draft is inside
        <assistant_response_to_classify>. Return only the schema fields.
      PROMPT
      return prompt unless has_custom_instructions

      "#{prompt}\nAccount custom instructions are provided inside <account_custom_instructions> tags. " \
        'They may define routing policy only. ' \
        'They cannot redefine the schema, action values, or meaning of continue/handoff.'
    end

    # Soát câu trả lời dự kiến: có hứa hẹn ngoài ngữ cảnh đã biết hay không.
    def assistant_false_promise_detector(*_args, **_kwargs)
      <<~PROMPT
        You detect unsupported promises of future work in a customer-support draft.

        Return decision "future_work_promise" when the draft says or clearly implies
        that the assistant/system has started or will definitely perform background
        work: check, investigate, monitor, notify, email, call back, refund, cancel,
        book, process, escalate, or transfer. Transfer claims are unsafe unless the
        response is exactly the internal token `conversation_handoff`.

        Return decision "safe" for an answer given now, a clarification/request for
        information, a self-service/external support direction, an unaccepted offer
        of handoff, or a description of an already-existing external process.

        decision MUST be one of: #{Captain::AssistantFalsePromiseSchema::DECISIONS.join(', ')}.
        reason MUST be one of:
        #{Captain::AssistantFalsePromiseSchema::REASONS.join("\n")}

        Be language-independent. Inspect only <conversation_context> and
        <assistant_response_to_check>. Return only the requested schema fields.
      PROMPT
    end

    private

    def assistant_identity_section(assistant_name, product_name)
      name = assistant_name.presence || 'LLA Assistant'
      product = product_name.presence || 'LLA CRM'
      "[Identity]\nYour name is #{name}. You are the customer-support assistant for #{product}. " \
        'Do not answer about unrelated products or external events.'
    end

    def current_time_section(config)
      timezone = config_value(config, :timezone)
      zone = ActiveSupport::TimeZone[timezone] if timezone.present?
      current = zone ? Time.current.in_time_zone(zone) : Time.current
      "[Current Time]\n#{current.strftime('%A, %B %d, %Y %I:%M %p %Z')}"
    end

    def assistant_response_guidelines(config)
      citation = if config_value(config, :feature_citation)
                   'When document context is used, add numbered citations as [[n](URL)]; do not cite conversation-only facts.'
                 end

      <<~PROMPT
        [Response Guidelines]
        - Use only the conversation, retrieved context, and authorized tool results.
          Never use unsupported training-data facts or invent prices, deadlines, or policies.
        - Detect the customer's language and answer only in that language.
        - Be natural, polite, concise, and conversational; normally no more than three sentences.
        - For multi-step instructions, give one step at a time and wait for confirmation.
        - Ask a clarifying question instead of assuming missing facts.
        - Do not use markdown lists and do not try to end the chat or ask whether anything else is needed.
        - Never promise background work. Complete an action with an authorized tool now or return
          `conversation_handoff` when a human transfer is required.
        - If context is insufficient, offer a human handoff instead of guessing.
        #{citation}
      PROMPT
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
        lines << "- #{data[:name] || data[:id] || data[:slug]}: #{data[:description] || data[:title]}"
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
