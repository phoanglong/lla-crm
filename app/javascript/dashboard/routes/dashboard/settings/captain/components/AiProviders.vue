<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import AiProvidersAPI from 'dashboard/api/aiProviders';
import NextButton from 'dashboard/components-next/button/Button.vue';

// Kết nối AI của chính tenant: khoá riêng, endpoint riêng, mô hình riêng. Mô hình được gọi
// bằng `<tên kết nối>/<tên mô hình>`, nên tên kết nối là thứ người dùng sẽ nhìn thấy lại.
const { t } = useI18n();

const KINDS = [
  'openai',
  'anthropic',
  'gemini',
  'azure_openai',
  'openai_compatible',
];
const NEEDS_BASE = ['azure_openai', 'openai_compatible'];

const providers = ref([]);
const isLoading = ref(true);
const isSaving = ref(false);
const verifying = ref('');
const showForm = ref(false);
const form = reactive({
  name: '',
  kind: 'openai_compatible',
  apiBase: '',
  apiKey: '',
});

const label = key => t(`CAPTAIN_SETTINGS.AI_PROVIDERS.${key}`);
const needsBase = computed(() => NEEDS_BASE.includes(form.kind));
const canSave = computed(
  () => form.name && form.apiKey && (!needsBase.value || form.apiBase)
);

const load = async () => {
  try {
    const { data } = await AiProvidersAPI.get();
    providers.value = data.providers;
  } finally {
    isLoading.value = false;
  }
};
onMounted(load);

const save = async () => {
  isSaving.value = true;
  try {
    await AiProvidersAPI.create({
      name: form.name.trim(),
      kind: form.kind,
      api_base: form.apiBase.trim() || undefined,
      api_key: form.apiKey.trim(),
    });
    Object.assign(form, {
      name: '',
      kind: 'openai_compatible',
      apiBase: '',
      apiKey: '',
    });
    showForm.value = false;
    await load();
  } catch (error) {
    useAlert(error.response?.data?.error || error.message);
  } finally {
    isSaving.value = false;
  }
};

// Kiểm tra là một lệnh gọi thật; kết quả trả về cũng chính là danh sách mô hình dùng được.
const verify = async provider => {
  verifying.value = provider.name;
  try {
    const { data } = await AiProvidersAPI.verify(provider.name);
    await AiProvidersAPI.update(provider.name, { models: data.models });
    await load();
    useAlert(label('VERIFY_OK'));
  } catch (error) {
    await load();
    useAlert(error.response?.data?.error || label('VERIFY_FAILED'));
  } finally {
    verifying.value = '';
  }
};

const remove = async provider => {
  await AiProvidersAPI.delete(provider.name);
  await load();
};
</script>

<template>
  <div v-if="!isLoading" class="flex flex-col gap-3">
    <ul v-if="providers.length" class="m-0 p-0 list-none flex flex-col gap-2">
      <li
        v-for="provider in providers"
        :key="provider.name"
        class="flex items-center justify-between gap-3 bg-n-solid-2 rounded-md outline outline-1 outline-n-container px-3 py-2"
      >
        <div class="min-w-0">
          <div class="text-sm text-n-slate-12">
            {{ provider.name }}
            <span class="text-n-slate-11">{{ `· ${provider.kind}` }}</span>
          </div>
          <div class="text-xs text-n-slate-11 truncate">
            {{ provider.api_base || label('DEFAULT_ENDPOINT') }}
            <template v-if="provider.models.length">
              {{ `· ${provider.models.length} ${label('MODELS_SUFFIX')}` }}
            </template>
          </div>
          <div v-if="provider.last_error" class="text-xs text-n-ruby-11">
            {{ provider.last_error }}
          </div>
        </div>
        <div class="flex items-center gap-2 shrink-0">
          <span
            class="rounded-full px-2 py-0.5 text-xs font-medium whitespace-nowrap"
            :class="
              provider.verified_at
                ? 'bg-n-teal-3 text-n-teal-11'
                : 'bg-n-alpha-2 text-n-slate-11'
            "
          >
            {{ provider.verified_at ? label('VERIFIED') : label('UNVERIFIED') }}
          </span>
          <NextButton
            faded
            slate
            type="button"
            :is-loading="verifying === provider.name"
            :label="label('VERIFY')"
            @click="verify(provider)"
          />
          <NextButton
            faded
            ruby
            type="button"
            :label="label('REMOVE')"
            @click="remove(provider)"
          />
        </div>
      </li>
    </ul>
    <p v-else class="text-sm text-n-slate-11">{{ label('EMPTY') }}</p>

    <div
      v-if="showForm"
      class="flex flex-col gap-2 bg-n-solid-2 rounded-md p-3"
    >
      <label>
        {{ label('NAME_LABEL') }}
        <input
          v-model="form.name"
          type="text"
          :placeholder="label('NAME_PLACEHOLDER')"
        />
      </label>
      <p class="help-text">{{ label('NAME_HELP') }}</p>

      <label>
        {{ label('KIND_LABEL') }}
        <select v-model="form.kind">
          <option v-for="kind in KINDS" :key="kind" :value="kind">
            {{ kind }}
          </option>
        </select>
      </label>

      <label v-if="needsBase">
        {{ label('BASE_LABEL') }}
        <input
          v-model="form.apiBase"
          type="url"
          :placeholder="label('BASE_PLACEHOLDER')"
        />
      </label>
      <p v-if="needsBase" class="help-text">{{ label('BASE_HELP') }}</p>

      <label>
        {{ label('KEY_LABEL') }}
        <input
          v-model="form.apiKey"
          type="password"
          autocomplete="off"
          :placeholder="label('KEY_PLACEHOLDER')"
        />
      </label>

      <div class="flex gap-2">
        <NextButton
          solid
          blue
          type="button"
          :is-loading="isSaving"
          :disabled="!canSave"
          :label="label('SAVE')"
          @click="save"
        />
        <NextButton
          faded
          slate
          type="button"
          :label="label('CANCEL')"
          @click="showForm = false"
        />
      </div>
    </div>
    <div v-else>
      <NextButton
        faded
        slate
        type="button"
        :label="label('ADD')"
        @click="showForm = true"
      />
    </div>
  </div>
</template>
