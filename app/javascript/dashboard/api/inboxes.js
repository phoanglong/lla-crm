/* global axios */
import CacheEnabledApiClient from './CacheEnabledApiClient';

const lifecycleIdempotencyKey = action =>
  window.crypto?.randomUUID?.() ||
  `voice-${action}-${Date.now()}-${Math.random().toString(36).slice(2)}`;

class Inboxes extends CacheEnabledApiClient {
  constructor() {
    super('inboxes', { accountScoped: true });
  }

  // eslint-disable-next-line class-methods-use-this
  get cacheModelName() {
    return 'inbox';
  }

  getCampaigns(inboxId) {
    return axios.get(`${this.url}/${inboxId}/campaigns`);
  }

  deleteInboxAvatar(inboxId) {
    return axios.delete(`${this.url}/${inboxId}/avatar`);
  }

  getAgentBot(inboxId) {
    return axios.get(`${this.url}/${inboxId}/agent_bot`);
  }

  setAgentBot(inboxId, botId) {
    return axios.post(`${this.url}/${inboxId}/set_agent_bot`, {
      agent_bot: botId,
    });
  }

  syncTemplates(inboxId) {
    return axios.post(`${this.url}/${inboxId}/sync_templates`);
  }

  createCSATTemplate(inboxId, template) {
    return axios.post(`${this.url}/${inboxId}/csat_template`, {
      template,
    });
  }

  getCSATTemplateStatus(inboxId) {
    return axios.get(`${this.url}/${inboxId}/csat_template`);
  }

  analyzeCSATTemplateUtility(inboxId, template) {
    return axios.post(`${this.url}/${inboxId}/csat_template/analyze`, {
      template,
    });
  }

  resetSecret(inboxId) {
    return axios.post(`${this.url}/${inboxId}/reset_secret`);
  }

  enableWhatsappCalling(inboxId, idempotencyKey = null) {
    return axios.post(
      `${this.url}/${inboxId}/enable_whatsapp_calling`,
      {},
      {
        headers: {
          'Idempotency-Key':
            idempotencyKey || lifecycleIdempotencyKey('enable'),
        },
      }
    );
  }

  disableWhatsappCalling(inboxId, idempotencyKey = null) {
    return axios.post(
      `${this.url}/${inboxId}/disable_whatsapp_calling`,
      {},
      {
        headers: {
          'Idempotency-Key':
            idempotencyKey || lifecycleIdempotencyKey('disable'),
        },
      }
    );
  }

  setInboundCalls(inboxId, enabled) {
    return axios.post(`${this.url}/${inboxId}/set_inbound_calls`, {
      inbound_calls_enabled: enabled,
    });
  }

  setVoiceRecording(inboxId, enabled, disclosureVersion = null) {
    return axios.post(`${this.url}/${inboxId}/set_voice_recording`, {
      voice_recording_enabled: enabled,
      disclosure_version: disclosureVersion,
    });
  }

  setWhatsappCallingMessage(inboxId, body) {
    return axios.post(`${this.url}/${inboxId}/set_whatsapp_calling_message`, {
      call_permission_request_body: body,
    });
  }
}

export default new Inboxes();
