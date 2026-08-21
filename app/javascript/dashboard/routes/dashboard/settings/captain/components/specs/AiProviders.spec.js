import { flushPromises, mount } from '@vue/test-utils';
import { afterEach, describe, expect, it, vi } from 'vitest';

import AiProviders from '../AiProviders.vue';
import AiProvidersAPI from 'dashboard/api/aiProviders';

vi.mock('dashboard/api/aiProviders', () => ({
  default: {
    get: vi.fn(),
    create: vi.fn(),
    update: vi.fn(),
    delete: vi.fn(),
    verify: vi.fn(),
  },
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const ButtonStub = {
  props: ['label', 'isLoading', 'disabled'],
  template:
    '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
};

const mountProviders = () =>
  mount(AiProviders, { global: { stubs: { NextButton: ButtonStub } } });

afterEach(() => vi.clearAllMocks());

describe('AiProviders', () => {
  it('says plainly that the platform AI is in use when there is no connection', async () => {
    AiProvidersAPI.get.mockResolvedValue({ data: { providers: [] } });
    const wrapper = mountProviders();
    await flushPromises();

    expect(wrapper.text()).toContain('CAPTAIN_SETTINGS.AI_PROVIDERS.EMPTY');
  });

  it('sends the connection the tenant described', async () => {
    AiProvidersAPI.get.mockResolvedValue({ data: { providers: [] } });
    AiProvidersAPI.create.mockResolvedValue({ data: {} });
    const wrapper = mountProviders();
    await flushPromises();

    await wrapper.findAll('button')[0].trigger('click'); // mở biểu mẫu
    const inputs = wrapper.findAll('input');
    await inputs[0].setValue('noi-bo');
    await inputs[1].setValue('https://llm.noi-bo.vn/v1');
    await inputs[2].setValue('khoa-cua-khach');
    await wrapper
      .findAll('button')
      .find(b => b.text() === 'CAPTAIN_SETTINGS.AI_PROVIDERS.SAVE')
      .trigger('click');
    await flushPromises();

    expect(AiProvidersAPI.create).toHaveBeenCalledWith({
      name: 'noi-bo',
      kind: 'openai_compatible',
      api_base: 'https://llm.noi-bo.vn/v1',
      api_key: 'khoa-cua-khach',
    });
  });

  // Endpoint là bắt buộc với hai loại tự đặt địa chỉ; không có thì nút lưu phải chặn.
  it('will not save a custom-endpoint connection without an endpoint', async () => {
    AiProvidersAPI.get.mockResolvedValue({ data: { providers: [] } });
    const wrapper = mountProviders();
    await flushPromises();

    await wrapper.findAll('button')[0].trigger('click');
    const inputs = wrapper.findAll('input');
    await inputs[0].setValue('noi-bo');
    await inputs[2].setValue('khoa');

    const save = wrapper
      .findAll('button')
      .find(b => b.text() === 'CAPTAIN_SETTINGS.AI_PROVIDERS.SAVE');
    expect(save.attributes('disabled')).toBeDefined();
  });

  it('writes back the models the provider actually reported', async () => {
    AiProvidersAPI.get.mockResolvedValue({
      data: {
        providers: [
          {
            name: 'noi-bo',
            kind: 'openai_compatible',
            api_base: 'https://x/v1',
            models: [],
            verified_at: null,
            last_error: null,
          },
        ],
      },
    });
    AiProvidersAPI.verify.mockResolvedValue({
      data: { ok: true, models: ['llama-3.1-70b'] },
    });
    AiProvidersAPI.update.mockResolvedValue({ data: {} });
    const wrapper = mountProviders();
    await flushPromises();

    await wrapper
      .findAll('button')
      .find(b => b.text() === 'CAPTAIN_SETTINGS.AI_PROVIDERS.VERIFY')
      .trigger('click');
    await flushPromises();

    expect(AiProvidersAPI.verify).toHaveBeenCalledWith('noi-bo');
    expect(AiProvidersAPI.update).toHaveBeenCalledWith('noi-bo', {
      models: ['llama-3.1-70b'],
    });
  });
});
