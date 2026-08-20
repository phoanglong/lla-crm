import { computed, unref } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { useConfig } from 'dashboard/composables/useConfig';
import {
  getUserPermissions,
  hasPermissions,
} from 'dashboard/helper/permissionsHelper';
import { PREMIUM_FEATURES } from 'dashboard/featureFlags';

export function usePolicy() {
  const user = useMapGetter('getCurrentUser');
  const isFeatureEnabled = useMapGetter('accounts/isFeatureEnabledonAccount');
  const isOnChatwootCloud = useMapGetter('globalConfig/isOnChatwootCloud');
  const isACustomBrandedInstance = useMapGetter(
    'globalConfig/isACustomBrandedInstance'
  );

  const { isEnterprise, enterprisePlanName } = useConfig();
  const { accountId } = useAccount();

  const getUserPermissionsForAccount = () => {
    return getUserPermissions(user.value, accountId.value);
  };

  const isFeatureFlagEnabled = featureFlag => {
    if (!featureFlag) return true;
    return isFeatureEnabled.value(accountId.value, featureFlag);
  };

  const checkPermissions = requiredPermissions => {
    if (!requiredPermissions || !requiredPermissions.length) return true;
    const userPermissions = getUserPermissionsForAccount();
    return hasPermissions(requiredPermissions, userPermissions);
  };

  const isPremiumFeature = featureFlag => {
    if (!featureFlag) return true;
    return PREMIUM_FEATURES.includes(featureFlag);
  };

  const hasPremiumEnterprise = computed(() => {
    if (isEnterprise) return enterprisePlanName !== 'community';

    return true;
  });

  // A capability is visible when the installation has it, not when the
  // installation is of a particular edition.
  //
  // The `installationTypes` argument this used to take was an edition gate:
  // `[CLOUD, ENTERPRISE]` on a product that is neither meant "never", so six
  // shipped capabilities were reachable only by typing their URL. It is gone —
  // the feature flag is the whole answer, and a route with no flag stays visible.
  const shouldShow = (featureFlag, permissions) => {
    const flag = unref(featureFlag);
    const perms = unref(permissions);

    // if the user does not have permissions, return false.
    // This supersedes everything
    if (!checkPermissions(perms)) return false;

    if (isACustomBrandedInstance.value) {
      // if this is a custom branded instance, we just use the feature flag as a reference
      return isFeatureFlagEnabled(flag);
    }

    // if on cloud, we should if the feature is allowed
    // or if the feature is a premium one like SLA to show a paywall
    // the paywall should be managed by the individual component
    if (isOnChatwootCloud.value) {
      return isFeatureFlagEnabled(flag) || isPremiumFeature(flag);
    }

    if (isEnterprise) {
      // in enterprise, if the feature is premium but they don't have an enterprise plan
      // we should it anyway this is to show upsells on enterprise regardless of the feature flag
      // Feature flag is only honored if they have a premium plan
      //
      // In case they have a premium plan, the check on feature flag alone is enough
      // because the second condition will always be false
      // That means once subscribed, the feature can be disabled by the admin
      //
      // the paywall should be managed by the individual component
      return (
        isFeatureFlagEnabled(flag) ||
        (isPremiumFeature(flag) && !hasPremiumEnterprise.value)
      );
    }

    // Anything else — a plain self-hosted installation that has not been
    // rebranded — answers with the capability too. This used to `return true`,
    // which ignored the feature flag entirely: with the edition gate removed,
    // that would have published every gated screen on such an installation.
    return isFeatureFlagEnabled(flag);
  };

  const shouldShowPaywall = featureFlag => {
    const flag = unref(featureFlag);
    if (!flag) return false;

    if (isACustomBrandedInstance.value) {
      // custom branded instances never show paywall
      return false;
    }

    if (isPremiumFeature(flag)) {
      if (isOnChatwootCloud.value) {
        return !isFeatureFlagEnabled(flag);
      }

      if (isEnterprise) {
        return !hasPremiumEnterprise.value;
      }
    }

    return false;
  };

  return {
    checkPermissions,
    shouldShowPaywall,
    isFeatureFlagEnabled,
    shouldShow,
  };
}
