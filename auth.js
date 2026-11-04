// Local demonstration only. Production identity is handled by Supabase Auth.
(function () {
  const key = 'tripmatch-password-accounts-v1';
  const accounts = () => JSON.parse(localStorage.getItem(key) || '{}');
  const publicUser = a => ({ id: a.id, nickname: a.nickname, phone: a.phone });
  async function digest(password, salt) {
    const material = await crypto.subtle.importKey('raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveBits']);
    const bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', salt: new TextEncoder().encode(salt), iterations: 210000, hash: 'SHA-256' }, material, 256);
    return Array.from(new Uint8Array(bits), b => b.toString(16).padStart(2, '0')).join('');
  }
  window.LocalAuth = {
    async register(phone, password, nickname) {
      if (!/^1\d{10}$/.test(phone)) throw new Error('请输入11位手机号');
      if (password.length < 8 || !nickname.trim()) throw new Error('请填写昵称和至少8位密码');
      if (accounts()[phone]) throw new Error('该手机号已注册，请登录');
      const salt = crypto.randomUUID(), passwordHash = await digest(password, salt);
      const all = accounts();
      if (all[phone]) throw new Error('该手机号已注册，请登录');
      const user = { id: 'local-' + crypto.randomUUID(), phone, nickname: nickname.trim(), salt, passwordHash };
      all[phone] = user;
      localStorage.setItem(key, JSON.stringify(all));
      return publicUser(user);
    },
    async login(phone, password) {
      const user = accounts()[phone];
      if (!user || await digest(password, user.salt) !== user.passwordHash) throw new Error('手机号或密码错误');
      return publicUser(user);
    }
  };
})();
