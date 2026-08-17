import WhatsappCallsAPI from '../channel/whatsapp/whatsappCallsAPI';
import ApiClient from '../ApiClient';

describe('#WhatsappCallsAPI', () => {
  const originalAxios = window.axios;
  const originalPath = window.location.pathname;
  const axiosMock = {
    get: vi.fn(() => Promise.resolve({ data: {} })),
    post: vi.fn(() => Promise.resolve({ data: { id: 42 } })),
  };

  beforeEach(() => {
    window.axios = axiosMock;
    window.history.replaceState({}, '', '/app/accounts/1/dashboard');
    vi.clearAllMocks();
  });

  afterAll(() => {
    window.axios = originalAxios;
    window.history.replaceState({}, '', originalPath);
  });

  it('creates an account-scoped API client', () => {
    expect(WhatsappCallsAPI).toBeInstanceOf(ApiClient);
    expect(WhatsappCallsAPI.url).toBe('/api/v1/accounts/1/whatsapp_calls');
  });

  it('sends an idempotency key with outbound call initiation', async () => {
    await WhatsappCallsAPI.initiate(
      { conversationId: 7, contactId: 8, inboxId: 9 },
      'v=0 offer'
    );

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/1/whatsapp_calls/initiate',
      {
        conversation_id: 7,
        contact_id: 8,
        inbox_id: 9,
        sdp_offer: 'v=0 offer',
        recording_consent: null,
      },
      {
        headers: {
          'Idempotency-Key': expect.stringMatching(/^[A-Za-z0-9_.:-]{8,128}$/),
        },
      }
    );
  });

  it('sends recording evidence when accepting an incoming call', async () => {
    const recordingConsent = {
      accepted: true,
      attestation_id: 'recording-consent-1',
      attested_at: '2026-08-17T00:00:00.000Z',
      disclosure_version: 'lla-voice-v1',
      method: 'agent_attestation',
    };

    await WhatsappCallsAPI.accept(42, 'v=0 answer', recordingConsent);

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/1/whatsapp_calls/42/accept',
      {
        sdp_answer: 'v=0 answer',
        recording_consent: recordingConsent,
      }
    );
  });
});
