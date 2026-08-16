import semver from 'semver';

export const resolveCompatibilityVersion = (globalConfig = {}) =>
  globalConfig.compatibilityVersion || globalConfig.appVersion;

export const hasAnUpdateAvailable = (latestVersion, currentVersion) => {
  if (!semver.valid(latestVersion)) {
    return false;
  }
  return semver.lt(currentVersion, latestVersion);
};
