import inboxesAPI from '../inboxes';
import ApiClient from '../ApiClient';

describe('#InboxesAPI', () => {
  it('creates correct instance', () => {
    expect(inboxesAPI).toBeInstanceOf(ApiClient);
    expect(inboxesAPI).toHaveProperty('get');
    expect(inboxesAPI).toHaveProperty('show');
    expect(inboxesAPI).toHaveProperty('create');
    expect(inboxesAPI).toHaveProperty('update');
    expect(inboxesAPI).toHaveProperty('delete');
    expect(inboxesAPI).toHaveProperty('getCampaigns');
    expect(inboxesAPI).toHaveProperty('getAgentBot');
    expect(inboxesAPI).toHaveProperty('setAgentBot');
    expect(inboxesAPI).toHaveProperty('syncTemplates');
  });

  describe('API calls', () => {
    const originalAxios = window.axios;
    const axiosMock = {
      post: vi.fn(() => Promise.resolve()),
      get: vi.fn(() => Promise.resolve()),
      patch: vi.fn(() => Promise.resolve()),
      delete: vi.fn(() => Promise.resolve()),
    };

    beforeEach(() => {
      window.axios = axiosMock;
    });

    afterEach(() => {
      window.axios = originalAxios;
    });

    it('#getCampaigns', () => {
      inboxesAPI.getCampaigns(2);
      expect(axiosMock.get).toHaveBeenCalledWith('/api/v1/inboxes/2/campaigns');
    });

    it('#deleteInboxAvatar', () => {
      inboxesAPI.deleteInboxAvatar(2);
      expect(axiosMock.delete).toHaveBeenCalledWith('/api/v1/inboxes/2/avatar');
    });

    it('#syncTemplates', () => {
      inboxesAPI.syncTemplates(2);
      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/sync_templates'
      );
    });

    it('#enableWhatsappCalling sends an idempotency key', () => {
      inboxesAPI.enableWhatsappCalling(2, 'enable-whatsapp-calling-1');
      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/enable_whatsapp_calling',
        {},
        { headers: { 'Idempotency-Key': 'enable-whatsapp-calling-1' } }
      );
    });

    it('#disableWhatsappCalling generates an idempotency key', () => {
      inboxesAPI.disableWhatsappCalling(2);
      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/disable_whatsapp_calling',
        {},
        {
          headers: {
            'Idempotency-Key': expect.stringMatching(
              /^[A-Za-z0-9_.:-]{8,128}$/
            ),
          },
        }
      );
    });

    it('#setVoiceRecording sends policy and disclosure version', () => {
      inboxesAPI.setVoiceRecording(2, true, 'lla-voice-v1');
      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/set_voice_recording',
        {
          voice_recording_enabled: true,
          disclosure_version: 'lla-voice-v1',
        }
      );
    });

    it('#setWhatsappCallingMessage sends only the editable message', () => {
      inboxesAPI.setWhatsappCallingMessage(2, 'May we call you?');
      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/set_whatsapp_calling_message',
        { call_permission_request_body: 'May we call you?' }
      );
    });
  });
});
