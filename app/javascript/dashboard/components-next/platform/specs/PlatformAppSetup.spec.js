import { flushPromises, mount } from '@vue/test-utils';
import { afterEach, describe, expect, it, vi } from 'vitest';

import PlatformAppSetup from '../PlatformAppSetup.vue';
import PlatformAppsAPI from 'dashboard/api/platformApps';

vi.mock('dashboard/api/platformApps', () => ({
  default: { show: vi.fn(), create: vi.fn() },
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('shared/helpers/clipboard', () => ({ copyTextToClipboard: vi.fn() }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const ButtonStub = {
  props: ['label', 'isLoading', 'disabled'],
  template:
    '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
};

const app = {
  platform: 'facebook',
  app_id: '123',
  webhook_url: 'https://crm.test/webhooks/tenant/facebook/tok',
  verify_token: 'verify-tok',
};

const mountSetup = (props = {}) =>
  mount(PlatformAppSetup, {
    props: { platform: 'facebook', ...props },
    global: { stubs: { NextButton: ButtonStub } },
  });

afterEach(() => vi.clearAllMocks());

describe('PlatformAppSetup', () => {
  it('asks for the app when the tenant has not registered one', async () => {
    PlatformAppsAPI.show.mockRejectedValue(new Error('not found'));
    const wrapper = mountSetup();
    await flushPromises();

    expect(wrapper.findAll('input').length).toBe(2);
  });

  it('shows the webhook URL and verify token to paste once saved', async () => {
    PlatformAppsAPI.show.mockRejectedValue(new Error('not found'));
    PlatformAppsAPI.create.mockResolvedValue({ data: app });
    const wrapper = mountSetup();
    await flushPromises();

    const inputs = wrapper.findAll('input');
    await inputs[0].setValue('123');
    await inputs[1].setValue('secret');
    await wrapper.findAll('button')[0].trigger('click');
    await flushPromises();

    expect(PlatformAppsAPI.create).toHaveBeenCalledWith({
      platform: 'facebook',
      app_id: '123',
      app_secret: 'secret',
    });
    expect(wrapper.text()).toContain(app.webhook_url);
    expect(wrapper.text()).toContain(app.verify_token);
  });

  // Bí mật đã ở phía máy chủ; giữ thêm một bản trong trang chỉ tạo thêm chỗ để rò rỉ.
  it('drops the app secret from the form once the server has it', async () => {
    PlatformAppsAPI.show.mockRejectedValue(new Error('not found'));
    PlatformAppsAPI.create.mockResolvedValue({ data: app });
    const wrapper = mountSetup();
    await flushPromises();

    const inputs = wrapper.findAll('input');
    await inputs[0].setValue('123');
    await inputs[1].setValue('secret');
    await wrapper.findAll('button')[0].trigger('click');
    await flushPromises();

    expect(wrapper.vm.form.appSecret).toBe('');
  });

  it('offers the platform app only where there is one to borrow', async () => {
    PlatformAppsAPI.show.mockRejectedValue(new Error('not found'));

    const without = mountSetup();
    await flushPromises();
    expect(without.findAll('button').length).toBe(1);

    const withShared = mountSetup({ platformAppAvailable: true });
    await flushPromises();
    expect(withShared.findAll('button').length).toBe(2);
  });

  // URL webhook và verify token chỉ xuất hiện ở màn hình này. Nhảy thẳng sang bước sau nghĩa
  // là tenant đã khai ứng dụng rồi thì không còn đường nào đọc lại hai giá trị họ phải dán
  // sang trang quản trị ứng dụng của mình.
  it('shows the webhook url and verify token again to a tenant that already registered', async () => {
    PlatformAppsAPI.show.mockResolvedValue({ data: app });
    const wrapper = mountSetup();
    await flushPromises();

    expect(wrapper.emitted('ready')).toBeUndefined();
    expect(wrapper.findAll('input').length).toBe(0);
    expect(wrapper.text()).toContain(app.webhook_url);
    expect(wrapper.text()).toContain(app.verify_token);

    await wrapper
      .findAll('button')
      .find(b => b.text() === 'INBOX_MGMT.PLATFORM_APP.CONTINUE_BUTTON')
      .trigger('click');

    expect(wrapper.emitted('ready')[0]).toEqual([app]);
  });
});
