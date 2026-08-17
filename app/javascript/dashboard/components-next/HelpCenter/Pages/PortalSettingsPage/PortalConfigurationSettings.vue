<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import AddCustomDomainDialog from 'dashboard/components-next/HelpCenter/Pages/PortalSettingsPage/AddCustomDomainDialog.vue';
import DNSConfigurationDialog from 'dashboard/components-next/HelpCenter/Pages/PortalSettingsPage/DNSConfigurationDialog.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  activePortal: {
    type: Object,
    required: true,
  },
  isFetchingStatus: {
    type: Boolean,
    required: true,
  },
  // Set by the parent only after the server has accepted a domain change. DNS
  // instructions are a success affordance: showing them for a rejected change
  // would tell the administrator to point a record at a domain we did not save.
  domainInstructionsFor: {
    type: String,
    default: '',
  },
});

const emit = defineEmits([
  'updatePortalConfiguration',
  'refreshStatus',
  'reverifyDomain',
  'closeInstructions',
  'sendCnameInstructions',
]);

// Provider status values that still mean "the edge is serving this hostname".
const PROVIDER_LIVE_STATUSES = ['active', 'staging_active', 'local'];

const { t } = useI18n();

const addCustomDomainDialogRef = ref(null);
const dnsConfigurationDialogRef = ref(null);

const customDomainAddress = computed(
  () => props.activePortal?.custom_domain || ''
);

// The server is the only source of truth for entitlement: an LLA capability flag,
// provider readiness and the caller's own permission. There is deliberately no
// hosting-plan check here.
const domainState = computed(() => props.activePortal?.ssl_settings || {});
const capabilityEnabled = computed(
  () => !!domainState.value.capability_enabled
);
const providerReady = computed(() => !!domainState.value.provider_ready);
const canManage = computed(() => !!domainState.value.can_manage);
const lifecycleState = computed(() => domainState.value.lifecycle_state || '');
const reverifyRequired = computed(() => !!domainState.value.reverify_required);
const manualIntervention = computed(
  () => !!domainState.value.manual_intervention_required
);
// Which administrator action the server says is currently possible. The client
// never infers this from the lifecycle string.
const reverifyAvailable = computed(
  () => !!domainState.value.reverify_available
);
const retryAvailable = computed(() => !!domainState.value.retry_available);

const isActive = computed(() => lifecycleState.value === 'active');
const providerLive = computed(
  () =>
    !domainState.value.status ||
    PROVIDER_LIVE_STATUSES.includes(domainState.value.status)
);
const isLive = computed(() => isActive.value && providerLive.value);
const isPending = computed(() =>
  ['requested', 'ownership_pending', 'provisioning'].includes(
    lifecycleState.value
  )
);
const isError = computed(() => lifecycleState.value === 'failed');

const statusText = computed(() => {
  if (manualIntervention.value)
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.STATUS.MANUAL_INTERVENTION'
    );
  if (lifecycleState.value === 'removing')
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.STATUS.REMOVING'
    );
  if (isError.value)
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.STATUS.ERROR'
    );
  if (lifecycleState.value === 'ownership_pending')
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.STATUS.OWNERSHIP_PENDING'
    );
  if (lifecycleState.value === 'provisioning')
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.STATUS.PROVISIONING'
    );
  if (isActive.value && reverifyRequired.value)
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.STATUS.REVERIFY_REQUIRED'
    );
  // Active but the provider has not reported the hostname as serving: never
  // rendered as "Live", and never rendered as nothing at all.
  if (isActive.value && !providerLive.value)
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.STATUS.PROVIDER_PENDING'
    );
  if (isLive.value)
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.STATUS.LIVE'
    );
  if (isPending.value)
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.STATUS.PENDING'
    );
  return t(
    'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.STATUS.PENDING'
  );
});

const statusColors = computed(() => {
  if (isLive.value && !reverifyRequired.value)
    return { text: 'text-n-teal-11', bubble: 'outline-n-teal-6 bg-n-teal-9' };
  if (isError.value || manualIntervention.value)
    return { text: 'text-n-ruby-11', bubble: 'outline-n-ruby-6 bg-n-ruby-9' };
  return { text: 'text-n-amber-11', bubble: 'outline-n-amber-6 bg-n-amber-9' };
});

// One explanatory line, ordered by what the administrator has to act on first.
const helperText = computed(() => {
  if (!canManage.value)
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.LIFECYCLE.NO_PERMISSION'
    );
  if (!capabilityEnabled.value)
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.LIFECYCLE.CAPABILITY_DISABLED'
    );
  if (manualIntervention.value)
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.LIFECYCLE.MANUAL_DESCRIPTION'
    );
  if (isError.value)
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.LIFECYCLE.FAILED_DESCRIPTION'
    );
  if (reverifyRequired.value)
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.LIFECYCLE.REVERIFY_DESCRIPTION'
    );
  if (lifecycleState.value === 'ownership_pending')
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.LIFECYCLE.OWNERSHIP_DESCRIPTION'
    );
  if (isActive.value && !providerLive.value)
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.LIFECYCLE.PROVIDER_PENDING_DESCRIPTION'
    );
  if (!providerReady.value)
    return t(
      'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.LIFECYCLE.PROVIDER_NOT_READY'
    );
  return '';
});

const canVerifyAgain = computed(
  () =>
    canManage.value &&
    capabilityEnabled.value &&
    (reverifyAvailable.value || retryAvailable.value)
);

const verifyAgainLabel = computed(() =>
  reverifyAvailable.value
    ? t(
        'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.LIFECYCLE.REVERIFY_BUTTON'
      )
    : t(
        'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.LIFECYCLE.RETRY_BUTTON'
      )
);

const updatePortalConfiguration = customDomain => {
  const portal = {
    id: props.activePortal?.id,
    custom_domain: customDomain,
  };
  emit('updatePortalConfiguration', portal);
  addCustomDomainDialogRef.value.dialogRef.close();
};

watch(
  () => props.domainInstructionsFor,
  value => {
    if (value) dnsConfigurationDialogRef.value?.dialogRef?.open();
  }
);

const closeDNSConfigurationDialog = () => {
  emit('closeInstructions');
  dnsConfigurationDialogRef.value.dialogRef.close();
};

const onClickRefreshSSLStatus = () => {
  emit('refreshStatus');
};

const onClickReverify = () => {
  emit('reverifyDomain');
};

const onClickSend = email => {
  emit('sendCnameInstructions', {
    portalSlug: props.activePortal?.slug,
    email,
  });
};
</script>

<template>
  <div class="flex flex-col w-full gap-6">
    <div class="flex flex-col gap-2">
      <h6 class="text-base font-medium text-n-slate-12">
        {{
          t(
            'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.HEADER'
          )
        }}
      </h6>
      <span class="text-sm text-n-slate-11">
        {{
          t(
            'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.DESCRIPTION'
          )
        }}
      </span>
    </div>
    <div class="flex flex-col w-full gap-4">
      <div class="flex items-center justify-between w-full gap-2">
        <div v-if="customDomainAddress" class="flex flex-col gap-1">
          <div class="flex items-center w-full h-8 gap-4">
            <label class="text-sm font-medium text-n-slate-12">
              {{
                t(
                  'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.LABEL'
                )
              }}
            </label>
            <span
              class="text-sm text-n-slate-12"
              data-testid="custom-domain-address"
            >
              {{ customDomainAddress }}
            </span>
          </div>
          <span
            v-if="helperText"
            class="text-sm text-n-slate-11"
            data-testid="custom-domain-helper"
          >
            {{ helperText }}
          </span>
        </div>
        <div class="flex items-center">
          <div v-if="customDomainAddress" class="flex items-center gap-3">
            <div
              v-if="statusText"
              v-tooltip="statusText"
              class="flex items-center gap-3 flex-shrink-0"
              data-testid="custom-domain-status"
            >
              <span
                class="size-1.5 rounded-full outline outline-2 block flex-shrink-0"
                :class="statusColors.bubble"
              />
              <span
                :class="statusColors.text"
                class="text-sm leading-[16px] font-medium"
              >
                {{ statusText }}
              </span>
            </div>
            <div v-if="statusText" class="w-px h-3 bg-n-weak" />
            <Button
              v-if="canVerifyAgain"
              slate
              sm
              link
              data-testid="custom-domain-reverify"
              :label="verifyAgainLabel"
              class="hover:!no-underline flex-shrink-0"
              @click="onClickReverify"
            />
            <Button
              v-if="canManage"
              slate
              sm
              link
              data-testid="custom-domain-edit"
              :label="
                t(
                  'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.EDIT_BUTTON'
                )
              "
              class="hover:!no-underline flex-shrink-0"
              @click="addCustomDomainDialogRef.dialogRef.open()"
            />
            <div class="w-px h-3 bg-n-weak" />
            <Button
              slate
              sm
              link
              icon="i-lucide-refresh-ccw"
              data-testid="custom-domain-refresh"
              :class="isFetchingStatus && 'animate-spin'"
              @click="onClickRefreshSSLStatus"
            />
          </div>
          <Button
            v-else
            :label="
              t(
                'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.ADD_BUTTON'
              )
            "
            color="slate"
            data-testid="custom-domain-add"
            :disabled="!canManage"
            @click="addCustomDomainDialogRef.dialogRef.open()"
          />
        </div>
      </div>
    </div>
    <AddCustomDomainDialog
      ref="addCustomDomainDialogRef"
      :mode="customDomainAddress ? 'edit' : 'add'"
      :custom-domain="customDomainAddress"
      @add-custom-domain="updatePortalConfiguration"
    />
    <DNSConfigurationDialog
      ref="dnsConfigurationDialogRef"
      :custom-domain="domainInstructionsFor || customDomainAddress"
      @close="closeDNSConfigurationDialog"
      @send="onClickSend"
    />
  </div>
</template>
