import { flushPromises, mount } from '@vue/test-utils';
import { afterEach, describe, expect, it, vi } from 'vitest';

import Zalo from '../Zalo.vue';
import ZaloConnectionsAPI from 'dashboard/api/zaloConnections';

vi.mock('dashboard/api/zaloConnections', () => ({
  default: { create: vi.fn(), status: vi.fn(), checkDomain: vi.fn() },
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('shared/helpers/clipboard', () => ({ copyTextToClipboard: vi.fn() }));

const connection = {
  id: 'ab12cd34',
  webhook_url: 'https://zbridge.test/webhook/zalo/c/ab12cd34/tok',
  oauth_url: 'https://zbridge.test/oauth/start?conn=ab12cd34',
  oauth_callback_url: 'https://zbridge.test/oauth/callback',
  status: { authorized: false },
};
const created = {
  connection,
  inbox: { id: 7, name: 'OA Sen' },
  required_events: ['user_send_text', 'follow'],
  checks: [
    { key: 'inbox_created', ok: true },
    { key: 'oauth_authorized', ok: false },
  ],
};

const ButtonStub = {
  props: ['label', 'isLoading', 'disabled'],
  template:
    '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
};

const mountWizard = () =>
  mount(Zalo, {
    global: {
      stubs: { PageHeader: true, NextButton: ButtonStub },
      mocks: { $t: key => key },
      plugins: [
        {
          install(app) {
            app.config.globalProperties.$t = key => key;
          },
        },
      ],
    },
  });

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('vue-router', () => ({ useRouter: () => ({ replace: vi.fn() }) }));

const fillCredentials = async wrapper => {
  const inputs = wrapper.findAll('input');
  await inputs[1].setValue('2222222222');
  await inputs[2].setValue('app-secret-value');
};

afterEach(() => {
  vi.clearAllMocks();
  vi.useRealTimers();
});

describe('Zalo onboarding wizard', () => {
  it('refuses to send an App ID that is not a Zalo App ID', async () => {
    const wrapper = mountWizard();
    const inputs = wrapper.findAll('input');
    await inputs[1].setValue('abc');
    await inputs[2].setValue('app-secret-value');

    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(ZaloConnectionsAPI.create).not.toHaveBeenCalled();
  });

  it('sends the credentials once and shows the URLs the operator has to paste', async () => {
    ZaloConnectionsAPI.create.mockResolvedValue({ data: created });
    const wrapper = mountWizard();
    await fillCredentials(wrapper);

    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(ZaloConnectionsAPI.create).toHaveBeenCalledWith({
      name: 'Zalo OA',
      app_id: '2222222222',
      app_secret: 'app-secret-value',
      oa_id: undefined,
    });
    const text = wrapper.text();
    expect(text).toContain(connection.webhook_url);
    expect(text).toContain(connection.oauth_callback_url);
    expect(text).toContain('user_send_text');
  });

  // Bí mật đã nằm ở cầu; giữ thêm một bản trong trang chỉ tạo thêm chỗ để rò rỉ.
  it('drops the App Secret from the form once the bridge has it', async () => {
    ZaloConnectionsAPI.create.mockResolvedValue({ data: created });
    const wrapper = mountWizard();
    await fillCredentials(wrapper);

    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(wrapper.vm.form.appSecret).toBe('');
  });

  it('keeps asking the server until the operator has finished in Zalo', async () => {
    vi.useFakeTimers();
    ZaloConnectionsAPI.create.mockResolvedValue({ data: created });
    ZaloConnectionsAPI.status.mockResolvedValue({
      data: {
        ...created,
        checks: [
          { key: 'inbox_created', ok: true },
          { key: 'oauth_authorized', ok: true },
        ],
      },
    });
    const wrapper = mountWizard();
    await fillCredentials(wrapper);
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(ZaloConnectionsAPI.status).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(5000);
    await flushPromises();

    expect(ZaloConnectionsAPI.status).toHaveBeenCalledWith('ab12cd34');
    expect(wrapper.vm.checks.find(c => c.key === 'oauth_authorized').ok).toBe(
      true
    );
  });

  it('stops polling when the operator leaves the page', async () => {
    vi.useFakeTimers();
    ZaloConnectionsAPI.create.mockResolvedValue({ data: created });
    ZaloConnectionsAPI.status.mockResolvedValue({ data: created });
    const wrapper = mountWizard();
    await fillCredentials(wrapper);
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    wrapper.unmount();
    await vi.advanceTimersByTimeAsync(20000);

    expect(ZaloConnectionsAPI.status).not.toHaveBeenCalled();
  });

  it('says a Zalo record exists but does not match the code entered', async () => {
    ZaloConnectionsAPI.create.mockResolvedValue({ data: created });
    ZaloConnectionsAPI.checkDomain.mockResolvedValue({
      data: { domain: 'sen.vn', codes: ['other'], found: true, matches: false },
    });
    const wrapper = mountWizard();
    await fillCredentials(wrapper);
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    wrapper.vm.domain.value = 'sen.vn';
    wrapper.vm.domain.code = 'abc123';
    await wrapper.vm.checkDomain();
    await flushPromises();

    expect(wrapper.vm.domainMessage).toContain('MISMATCH');
  });
});
