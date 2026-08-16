import {
  hasAnUpdateAvailable,
  resolveCompatibilityVersion,
} from '../versionCheckHelper';

describe('#resolveCompatibilityVersion', () => {
  it('uses the upstream compatibility version for update checks', () => {
    expect(
      resolveCompatibilityVersion({
        appVersion: '0.9.0-dev.1',
        compatibilityVersion: '4.16.2',
      })
    ).toBe('4.16.2');
  });

  it('falls back to the product version for older global config payloads', () => {
    expect(resolveCompatibilityVersion({ appVersion: '4.16.2' })).toBe(
      '4.16.2'
    );
  });
});

describe('#hasAnUpdateAvailable', () => {
  it('return false if latest version is invalid', () => {
    expect(hasAnUpdateAvailable('invalid', '1.0.0')).toBe(false);
    expect(hasAnUpdateAvailable(null, '1.0.0')).toBe(false);
    expect(hasAnUpdateAvailable(undefined, '1.0.0')).toBe(false);
    expect(hasAnUpdateAvailable('', '1.0.0')).toBe(false);
  });

  it('return correct value if latest version is valid', () => {
    expect(hasAnUpdateAvailable('1.1.0', '1.0.0')).toBe(true);
    expect(hasAnUpdateAvailable('0.1.0', '1.0.0')).toBe(false);
  });
});
