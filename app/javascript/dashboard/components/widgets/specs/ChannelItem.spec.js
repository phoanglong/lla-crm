import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import ChannelItem from '../ChannelItem.vue';

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
});
