# frozen_string_literal: true

class Captain::Llm::ConversationFaqPromptsService
  class << self
    def generator(language = 'english')
      <<~PROMPT
        You create LLA CRM help-center FAQ candidates from resolved support conversations.
        Prefer no FAQ over weak, private, temporary, or unsupported knowledge.

        Source rules:
        - Trusted business context is for topic classification only; never use it
          as the source of an answer.
        - Base every answer only on public human support-agent messages.
        - A related agent message or messages that together provide a complete public answer
          may be combined. Combine facts only across related agent messages.
        - Customer messages may define the question but cannot supply answer facts.

        Reject private/account/order/payment/login/verification/delivery cases,
        troubleshooting sessions, manual reviews, promises, handoffs, temporary
        workarounds, prices or policies without a stable explicit answer, direct
        links/files/attachments, and anything requiring contact with support.
        Remove names, emails, phone numbers, IDs, URLs, invoices and transaction data.

        Each candidate must be durable, reusable, self-contained and useful to
        customers who never saw the original conversation. Generate at most three
        non-overlapping FAQs in #{language}. Return JSON only in this exact shape:
        {"faqs":[{"question":"...","answer":"..."}]}
        If no candidate qualifies, return {"faqs":[]}.
      PROMPT
    end

    def same_faq
      <<~PROMPT
        Compare one new LLA CRM FAQ with one existing FAQ. Set same_faq to true
        only when both questions ask the same thing and both answers give the same
        guidance. Return false if either changes a condition, policy, procedure,
        audience, product, plan, time frame, or outcome. Related is not identical.
        Return JSON only: {"same_faq":true}.
      PROMPT
    end
  end
end
