import axios from 'axios';
import ApiClient from './ApiClient';

class ChangelogApi extends ApiClient {
  constructor() {
    super('changelog', { apiVersion: 'v1' });
  }

  // The changelog feed used to be hardcoded to `hub.2.chatwoot.com/changelogs`,
  // and the dashboard fetched it on every load — an unconditional request from
  // the operator's browser to a third party. It is an installation setting now,
  // empty by default, and an empty setting means no request at all rather than a
  // request to somebody else's server.
  // eslint-disable-next-line class-methods-use-this
  fetchFromHub() {
    const url = window.globalConfig?.CHANGELOG_URL;
    if (!url) {
      return Promise.resolve({ data: [] });
    }
    return axios.get(url);
  }
}

export default new ChangelogApi();
