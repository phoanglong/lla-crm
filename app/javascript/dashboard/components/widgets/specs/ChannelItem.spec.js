import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import ChannelItem from '../ChannelItem.vue';

let accountRecord = null;
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: name =>
    name === 'accounts/getAccount'
      ? { value: () => accountRecord }
      : { value: 1 },
}));

const ChannelSelectorStub = {
  props: ['disabled'],
  emits: ['click'],
  template: '<button :disabled="disabled" @click="$emit(\'click\')" />',
};

describe('ChannelItem', () => {
  it('keeps the Zalo OA card active when account features are loaded', async () => {
    const wrapper = mount(ChannelItem, {
      props: {
        channel: {
          key: 'zalo',
          title: 'Zalo OA',
          description: 'LLA Zalo bridge',
          icon: 'i-woot-zalo',
        },
        enabledFeatures: { channel_website: true },
      },
      global: {
        stubs: { ChannelSelector: ChannelSelectorStub },
      },
    });

    expect(wrapper.get('button').attributes('disabled')).toBeUndefined();
    await wrapper.get('button').trigger('click');
    expect(wrapper.emitted('channelItemClick')).toEqual([['zalo']]);
  });

  // Bản cài đặt không có ứng dụng Facebook nào, nhưng tenant đã khai ứng dụng của họ —
  // đúng trường hợp LLA làm nhà cung cấp dịch vụ chứ không phải chủ tài khoản.
  it('keeps the Facebook card usable when only the tenant has an app', async () => {
    accountRecord = {
      platform_apps: { facebook: { app_id: 'app-cua-tenant' } },
    };
    window.chatwootConfig = {};

    const wrapper = mount(ChannelItem, {
      props: {
        channel: {
          key: 'facebook',
          title: 'Facebook',
          description: '',
          icon: 'i-ri-facebook',
        },
        enabledFeatures: { channel_facebook: true },
      },
      global: { stubs: { ChannelSelector: ChannelSelectorStub } },
    });

    expect(wrapper.get('button').attributes('disabled')).toBeUndefined();
  });

  it('leaves the Facebook card disabled when neither side has an app', () => {
    accountRecord = null;
    window.chatwootConfig = {};

    const wrapper = mount(ChannelItem, {
      props: {
        channel: {
          key: 'facebook',
          title: 'Facebook',
          description: '',
          icon: 'i-ri-facebook',
        },
        enabledFeatures: { channel_facebook: true },
      },
      global: { stubs: { ChannelSelector: ChannelSelectorStub } },
    });

    expect(wrapper.get('button').attributes('disabled')).toBeDefined();
  });
});
