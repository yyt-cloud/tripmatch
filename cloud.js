(function () {
  const config = window.TRIPMATCH_CONFIG || {};
  const enabled = Boolean(config.supabaseUrl && config.supabaseAnonKey);
  const endpoint = config.supabaseUrl ? `${config.supabaseUrl.replace(/\/$/, '')}/rest/v1/rpc` : '';

  async function rpc(name, body = {}) {
    if (!enabled) throw new Error('云端服务尚未配置');
    const response = await fetch(`${endpoint}/${name}`, {
      method: 'POST',
      headers: {
        apikey: config.supabaseAnonKey,
        Authorization: `Bearer ${config.supabaseAnonKey}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(body)
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(result.message || '云端请求失败');
    return result;
  }

  window.TripCloud = {
    enabled,
    createTrip: (trip, ownerToken) => rpc('create_trip', { payload: trip, owner_token: ownerToken }),
    getTrip: inviteCode => rpc('get_trip', { invite_code: inviteCode }),
    submitPreference: (inviteCode, participantToken, preference) => rpc('submit_preference', {
      invite_code: inviteCode,
      participant_token: participantToken,
      payload: preference
    }),
    organizerDashboard: ownerToken => rpc('get_organizer_dashboard', { owner_token: ownerToken }),
    participantStatus: participantToken => rpc('get_participant_status', { participant_token: participantToken }),
    publishGroups: (ownerToken, groups) => rpc('publish_groups', { owner_token: ownerToken, payload: groups })
  };
})();
